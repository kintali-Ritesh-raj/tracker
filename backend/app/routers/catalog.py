"""Teams and sites management."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import Employee, Site, Team
from ..schemas import SiteIn, SiteOut, SitePatch, TeamIn, TeamOut, TeamPatch
from ..security import current_device, require_admin

router = APIRouter(tags=["catalog"])


def _team_out(db: Session, team: Team) -> TeamOut:
    count = db.scalar(
        select(func.count()).select_from(Employee).where(Employee.team_id == team.id, Employee.active.is_(True))
    )
    out = TeamOut.model_validate(team)
    out.employee_count = count or 0
    return out


def _commit_unique(db: Session, message: str) -> None:
    try:
        db.commit()
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, message) from exc


@router.get("/teams", response_model=list[TeamOut], dependencies=[Depends(require_admin)])
def list_teams(db: Session = Depends(get_db)) -> list[TeamOut]:
    return [_team_out(db, t) for t in db.scalars(select(Team).order_by(Team.name))]


@router.post("/teams", response_model=TeamOut, status_code=201, dependencies=[Depends(require_admin)])
def create_team(body: TeamIn, db: Session = Depends(get_db)) -> TeamOut:
    team = Team(**body.model_dump())
    db.add(team)
    _commit_unique(db, "A team with this name already exists.")
    return _team_out(db, team)


@router.patch("/teams/{team_id}", response_model=TeamOut, dependencies=[Depends(require_admin)])
def update_team(team_id: int, body: TeamPatch, db: Session = Depends(get_db)) -> TeamOut:
    team = db.get(Team, team_id)
    if team is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Team not found.")
    for key, value in body.model_dump(exclude_unset=True).items():
        setattr(team, key, value)
    _commit_unique(db, "A team with this name already exists.")
    return _team_out(db, team)


@router.delete("/teams/{team_id}", status_code=204, response_class=Response, response_model=None, dependencies=[Depends(require_admin)])
def delete_team(team_id: int, db: Session = Depends(get_db)) -> None:
    team = db.get(Team, team_id)
    if team is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Team not found.")
    db.delete(team)  # employees keep working, just unassigned (ON DELETE SET NULL)
    db.commit()


# Sites are readable by employees too so the phone can show which site it is at.
@router.get("/sites", response_model=list[SiteOut], dependencies=[Depends(current_device)])
def list_sites(db: Session = Depends(get_db)) -> list[SiteOut]:
    return [SiteOut.model_validate(s) for s in db.scalars(select(Site).order_by(Site.name))]


@router.post("/sites", response_model=SiteOut, status_code=201, dependencies=[Depends(require_admin)])
def create_site(body: SiteIn, db: Session = Depends(get_db)) -> SiteOut:
    site = Site(**body.model_dump())
    db.add(site)
    db.commit()
    return SiteOut.model_validate(site)


@router.patch("/sites/{site_id}", response_model=SiteOut, dependencies=[Depends(require_admin)])
def update_site(site_id: int, body: SitePatch, db: Session = Depends(get_db)) -> SiteOut:
    site = db.get(Site, site_id)
    if site is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Site not found.")
    for key, value in body.model_dump(exclude_unset=True).items():
        setattr(site, key, value)
    db.commit()
    return SiteOut.model_validate(site)


@router.delete("/sites/{site_id}", status_code=204, response_class=Response, response_model=None, dependencies=[Depends(require_admin)])
def delete_site(site_id: int, db: Session = Depends(get_db)) -> None:
    site = db.get(Site, site_id)
    if site is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Site not found.")
    db.delete(site)
    db.commit()
