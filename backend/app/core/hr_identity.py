"""Explicit employee/account identity, shared by HR reads and delivery."""
from dataclasses import dataclass
from sqlalchemy import and_, or_, false, func, select
from app.core.models import Employee

@dataclass(frozen=True)
class HRTarget:
    code: str = ''
    uid: str = ''
    email: str = ''
    name: str = ''
    deleted: bool = False

    @classmethod
    def from_employee(cls, row):
        return cls(code=str(getattr(row,'code','') or ''),
            uid=str(getattr(row,'user_uid','') or ''),
            email=str(getattr(row,'user_email','') or ''),
            name=str(getattr(row,'name','') or ''),
            deleted=getattr(row,'is_deleted',False) is True)

    def matches_account(self, profile: dict) -> bool:
        uid = str(profile.get('uid', '') or '')
        email = str(profile.get('email', '') or '').strip().lower()
        if self.uid:
            return bool(uid and uid == self.uid)
        return bool(email and self.email and email == self.email.strip().lower())

    def is_self(self, profile: dict) -> bool:
        return not self.deleted and self.matches_account(profile)

    def for_recipient(self, profile: dict) -> dict:
        return {'employee_code': self.code, 'is_self': self.is_self(profile)}


def employee_self_clause(profile: dict):
    """UID is authoritative per row; a conflicting email is not a second link."""
    clauses=[]
    uid=str(profile.get('uid','') or '')
    email=str(profile.get('email','') or '').strip().lower()
    if uid:clauses.append(Employee.user_uid==uid)
    if email:
        clauses.append(and_(or_(Employee.user_uid.is_(None),Employee.user_uid==''),
            func.lower(func.trim(Employee.user_email))==email))
    return or_(*clauses) if clauses else false()


async def own_employee_codes(db,company: str,profile: dict) -> set[str]:
    result=await db.execute(select(Employee.code).where(Employee.company_code==str(company),
        Employee.is_deleted.is_(False),employee_self_clause(profile)))
    return {str(code) for code in result.scalars().all()}


async def resolve_own_employee_code(db,company: str,profile: dict):
    """Prefer a unique explicit UID link; never choose among ambiguous links."""
    uid=str(profile.get('uid','') or '')
    if uid:
        result=await db.execute(select(Employee.code).where(Employee.company_code==str(company),
            Employee.is_deleted.is_(False),Employee.user_uid==uid).limit(2))
        codes=list(result.scalars().all())
        if codes:return str(codes[0]) if len(codes)==1 else None
    result=await db.execute(select(Employee.code).where(Employee.company_code==str(company),
        Employee.is_deleted.is_(False),employee_self_clause(profile)).limit(2))
    codes=list(result.scalars().all())
    return str(codes[0]) if len(codes)==1 else None
