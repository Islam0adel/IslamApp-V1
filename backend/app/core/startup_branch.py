"""Startup selection never changes operating or HR work branch scope."""
from app.core.branch_catalog import company_branch_catalog
from fastapi import HTTPException


async def validate_startup_branch(session, *, company_code, value, allowed_branches):
    branch = value.strip()
    if branch in ('', 'all', 'الكل', 'كل الفروع'):
        # Empty selection means all already-permitted branches, not a grant.
        return ''
    scope = allowed_branches
    if scope is None or scope == []:
        scope = ['all']  # Preserve the existing legacy stored-scope meaning.
    elif isinstance(scope, str):
        scope = [scope]
    if (not isinstance(scope, list) or any(not isinstance(code, str) for code in scope)):
        raise HTTPException(status_code=409, detail='راجع الفروع المسموحة قبل اختيار فرع البداية')
    if not any(code.lower() == 'all' for code in scope) and branch not in scope:
        raise HTTPException(status_code=400, detail='فرع البداية يجب أن يكون ضمن الفروع المسموحة للمستخدم')
    exists = branch in await company_branch_catalog(session,company_code)
    if not exists:
        raise HTTPException(status_code=400, detail='فرع البداية غير موجود في هذه الشركة')
    return branch
