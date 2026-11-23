"""Run the actual additive startup DDL against a disposable old-schema company table."""
import asyncio
import pytest
from sqlalchemy import text
from app.core import database, models
from app.core.company_policy_store import active_policy_configuration, CompanyReviewRequired
from app.routes import auth
from test_postgres_save_concurrency import URL, run_case
from test_permission_editor_integration import fixture
pytestmark=pytest.mark.skipif(not URL,reason='opt-in disposable PostgreSQL regression')


def test_startup_migration_preserves_existing_companies_and_never_clears_new_review(tmp_path,monkeypatch):
    async def work(factory):
        engine=factory.kw['bind']
        monkeypatch.setattr(database,'engine',engine)
        async with engine.begin() as connection:
            await connection.execute(text('ALTER TABLE companies DROP COLUMN requires_permission_review'))
            await connection.execute(text("INSERT INTO companies(code,name,is_active) VALUES ('OLD','Existing fixture',TRUE)"))
        await database.create_tables()
        async with factory() as session:
            old=await session.get(models.Company,'OLD')
            assert old.requires_permission_review is False
            assert await active_policy_configuration(session,'OLD')==(None,None)
            session.add(models.Company(code='NEW',name='New fixture',is_active=True,requires_permission_review=True));await session.commit()
        await database.create_tables()
        async with factory() as session:
            assert (await session.get(models.Company,'OLD')).requires_permission_review is False
            assert (await session.get(models.Company,'NEW')).requires_permission_review is True
            with pytest.raises(CompanyReviewRequired):await active_policy_configuration(session,'NEW')
    asyncio.run(run_case(work))
