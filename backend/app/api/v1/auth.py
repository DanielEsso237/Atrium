"""Authentification (exigence 6.2) : connexion, rafraichissement, deconnexion.

Jeton d'acces court (JWT, 60 min) + jeton de rafraichissement long et opaque
(30 jours glissants, stocke hache dans `refresh_tokens`). En mode kiosque, la
tablette echange son jeton de rafraichissement avant l'expiration de l'acces :
un service de huit heures ne redemande jamais le mot de passe.

Cycle de vie d'une ligne `refresh_tokens` :

- `revoked_at` renseigne = **echange** (rotation) : le jeton a servi une
  fois. Il reste accepte `refresh_reuse_grace_seconds` pour absorber une
  reponse perdue sur le reseau ; apres, sa reutilisation signale un vol.
- ligne **supprimee** = invalide pour toujours (deconnexion, vol detecte,
  expiration). Pas de suppression logique ici : la table ne quitte jamais le
  serveur, aucune tablette n'a besoin de voir la suppression passer.
"""

from __future__ import annotations

import datetime as dt
import uuid

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from sqlalchemy import delete, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user, permission_codes
from app.core.config import settings
from app.core.security import (
    create_access_token,
    hash_refresh_token,
    hash_secret,
    new_refresh_token,
    secret_accepte,
)
from app.db.session import get_session
from app.models import AuditLog, Device, RefreshToken, User
from app.schemas.auth import (
    AuthorizeIn,
    AuthorizeOut,
    CredentialOut,
    LoginIn,
    RefreshIn,
    ResetSecretIn,
    ResetSecretOut,
    TokenOut,
    UserOut,
)
from app.services.verrouillage import (
    DROIT_REINITIALISER,
    compter_echec,
    debloquer,
    est_verrouille,
)

router = APIRouter(prefix="/auth", tags=["authentification"])

# Jetons echanges conserves un jour pour la detection de reutilisation, puis
# purges au fil des rafraichissements de l'utilisateur.
_ROTATED_RETENTION = dt.timedelta(days=1)


async def _issue_tokens(
    session: AsyncSession,
    user: User,
    device_id: uuid.UUID | None,
    user_agent: str | None,
    now: dt.datetime,
) -> TokenOut:
    plain, token_hash = new_refresh_token()
    session.add(
        RefreshToken(
            user_id=user.id,
            device_id=device_id,
            token_hash=token_hash,
            expires_at=now + dt.timedelta(days=settings.refresh_token_expire_days),
            user_agent=(user_agent or "")[:255] or None,
        )
    )
    return TokenOut(
        access_token=create_access_token(user.id),
        expires_in=settings.access_token_expire_minutes * 60,
        refresh_token=plain,
        refresh_expires_in=settings.refresh_token_expire_days * 86400,
    )


@router.post("/login", response_model=TokenOut)
async def login(
    payload: LoginIn, request: Request, session: AsyncSession = Depends(get_session)
) -> TokenOut:
    result = await session.execute(
        select(User).where(
            User.employee_code == payload.employee_code, User.deleted_at.is_(None)
        )
    )
    user = result.scalar_one_or_none()

    invalid = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Identifiant ou mot de passe incorrect.",
    )
    if user is None:
        raise invalid

    now = dt.datetime.now(dt.timezone.utc)
    if est_verrouille(user, now):
        raise HTTPException(
            status_code=status.HTTP_423_LOCKED,
            detail="Compte bloque apres cinq codes faux : un responsable doit le debloquer.",
        )

    # Mot de passe **ou** code PIN : sur une tablette de comptoir que dix
    # agents se passent dans la journee, taper un mot de passe complet a chaque
    # releve est intenable -- c'est pour ca que l'ecran de connexion propose un
    # pave numerique. Le PIN etait hache et stocke depuis le debut, mais jamais
    # verifie : il ne fonctionnait donc qu'en mode hors ligne.
    #
    # Quatre chiffres se devinent, evidemment. Ce qui protege ici n'est pas la
    # longueur du secret mais le blocage au bout de cinq essais
    # (`app/services/verrouillage.py`), et le fait que la tablette soit
    # derriere un comptoir.
    if not secret_accepte(payload.password, user.password_hash, user.pin_hash):
        compter_echec(user, now)
        await session.commit()
        raise invalid

    if not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="Compte desactive."
        )

    if payload.device_id is not None:
        device = await session.get(Device, payload.device_id)
        if device is None or device.hotel_id != user.hotel_id or device.deleted_at is not None:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Appareil inconnu.")

    debloquer(user)
    user.last_login_at = now
    tokens = await _issue_tokens(
        session, user, payload.device_id, request.headers.get("user-agent"), now
    )
    await session.commit()
    return tokens


@router.post("/refresh", response_model=TokenOut)
async def refresh(
    payload: RefreshIn, request: Request, session: AsyncSession = Depends(get_session)
) -> TokenOut:
    """Echange un jeton de rafraichissement contre une nouvelle paire.

    La ligne est verrouillee le temps de l'echange : deux envois simultanes
    du meme jeton (double tap, nouvelle tentative reseau) passent l'un apres
    l'autre, le second tombe dans la fenetre de tolerance.
    """
    unauthorized = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Session expiree, reconnectez-vous.",
        headers={"WWW-Authenticate": "Bearer"},
    )
    now = dt.datetime.now(dt.timezone.utc)
    token = await session.scalar(
        select(RefreshToken)
        .where(RefreshToken.token_hash == hash_refresh_token(payload.refresh_token))
        .with_for_update()
    )
    if token is None:
        raise unauthorized

    if token.expires_at <= now:
        await session.delete(token)
        await session.commit()
        raise unauthorized

    if token.revoked_at is not None:
        grace = dt.timedelta(seconds=settings.refresh_reuse_grace_seconds)
        if now - token.revoked_at > grace:
            # Jeton deja echange, presente bien apres : quelqu'un d'autre le
            # detient. On coupe toutes les sessions de cet appareil (ou de
            # l'utilisateur si le jeton n'etait rattache a aucun appareil).
            scope = RefreshToken.user_id == token.user_id
            if token.device_id is not None:
                scope = scope & (RefreshToken.device_id == token.device_id)
            await session.execute(delete(RefreshToken).where(scope))
            await session.commit()
            raise unauthorized

    user = await session.get(User, token.user_id)
    if (
        user is None
        or user.deleted_at is not None
        or not user.is_active
        or (user.locked_until is not None and user.locked_until > now)
    ):
        await session.delete(token)
        await session.commit()
        raise unauthorized

    if token.revoked_at is None:
        token.revoked_at = now

    # Menage opportuniste : les jetons expires ou echanges depuis longtemps
    # de cet utilisateur. Une requete indexee, et la table ne grossit pas.
    await session.execute(
        delete(RefreshToken).where(
            RefreshToken.user_id == user.id,
            or_(
                RefreshToken.expires_at <= now,
                RefreshToken.revoked_at < now - _ROTATED_RETENTION,
            ),
        )
    )
    tokens = await _issue_tokens(
        session, user, token.device_id, request.headers.get("user-agent"), now
    )
    await session.commit()
    return tokens


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def logout(payload: RefreshIn, session: AsyncSession = Depends(get_session)) -> Response:
    """Revoque le jeton de rafraichissement presente. Idempotent : un jeton

    inconnu repond aussi 204, pour ne rien apprendre a qui essaie des valeurs.
    Le jeton d'acces en cours expire de lui-meme (60 min au plus).
    """
    await session.execute(
        delete(RefreshToken).where(
            RefreshToken.token_hash == hash_refresh_token(payload.refresh_token)
        )
    )
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/me", response_model=UserOut)
async def me(user: User = Depends(get_current_user)) -> User:
    return user


@router.post("/authorize", response_model=AuthorizeOut)
async def authorize(
    payload: AuthorizeIn,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
) -> AuthorizeOut:
    """Un responsable donne son code sur la tablette d'un agent.

    Demande du 16 octobre : revenir sur une arrivee, un depart ou un
    encaissement exige le code d'un superieur, **meme quand c'est lui qui est
    connecte** -- l'agent doit aller le chercher, et le responsable le saisir.
    Aucune session n'est ouverte : on verifie le secret et le droit, puis on
    rend qui a autorise. Le geste lui-meme repart par la file d'envoi, avec
    cet identifiant, et le serveur reverifie le droit a ce moment-la.

    Reserve a un agent connecte, et soumis au meme verrouillage que la
    connexion : sans cela, la route servirait a deviner des PIN.
    """
    # 403 et non 401 : un 401 dit a la tablette que la session de l'agent
    # connecte est finie, et elle le deconnecterait pour un code mal tape.
    refus = HTTPException(status.HTTP_403_FORBIDDEN, "Code du responsable incorrect.")
    responsable = await session.scalar(
        select(User).where(
            User.employee_code == payload.employee_code.strip().upper(),
            User.hotel_id == user.hotel_id,
            User.deleted_at.is_(None),
        )
    )
    if responsable is None:
        raise refus
    now = dt.datetime.now(dt.timezone.utc)
    if est_verrouille(responsable, now):
        raise HTTPException(
            status.HTTP_423_LOCKED,
            "Compte du responsable bloque apres cinq codes faux.",
        )
    if not secret_accepte(payload.secret, responsable.password_hash, responsable.pin_hash):
        compter_echec(responsable, now)
        await session.commit()
        raise refus
    if not responsable.is_active:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Compte du responsable desactive.")
    debloquer(responsable)
    await session.commit()
    # populate_existing : les roles et leurs droits relus apres le commit,
    # meme quand le responsable est l'agent connecte.
    responsable = await session.get(User, responsable.id, populate_existing=True)
    if payload.permission not in permission_codes(responsable):
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            f"{responsable.first_name} {responsable.last_name} n'a pas le droit "
            f"d'autoriser ce geste (permission {payload.permission}).",
        )
    return AuthorizeOut(
        user_id=responsable.id,
        first_name=responsable.first_name,
        last_name=responsable.last_name,
    )


@router.post("/reset-secret", response_model=ResetSecretOut)
async def reset_secret(
    payload: ResetSecretIn, session: AsyncSession = Depends(get_session)
) -> ResetSecretOut:
    """Code oublie : un responsable le reinitialise sur la tablette de l'agent.

    Decision du 21 octobre. L'agent touche « Code oublie ? », un responsable
    (`users.reset_secret`) tape **son** code, l'agent choisit un nouveau PIN,
    un nouveau mot de passe, ou les deux. Le compte est debloque.

    **Sans session**, et c'est voulu : l'agent qui a oublie son code n'a pas
    de jeton, et hors ligne la tablette enfile ce geste pour plus tard. Il
    remonte alors avant meme que l'agent se reconnecte en ligne -- sinon le
    serveur refuserait le nouveau code qu'il ne connait pas encore. C'est le
    code du responsable, verifie ici, qui tient lieu de session ; il subit le
    meme blocage que la connexion, sans quoi la route servirait a deviner des
    PIN.

    Rejouable : renvoyer le meme corps laisse le meme etat.
    """
    refus = HTTPException(status.HTTP_403_FORBIDDEN, "Code du responsable incorrect.")
    agent = await session.scalar(
        select(User).where(
            User.employee_code == payload.employee_code.strip().upper(),
            User.deleted_at.is_(None),
        )
    )
    if agent is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Agent inconnu.")
    responsable = await session.scalar(
        select(User).where(
            User.employee_code == payload.approver_code.strip().upper(),
            User.hotel_id == agent.hotel_id,
            User.deleted_at.is_(None),
        )
    )
    if responsable is None:
        raise refus
    # Le second regard : celui qui a oublie son code ne se l'accorde pas.
    if responsable.id == agent.id:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            "Un autre responsable doit valider : on ne reinitialise pas son propre code.",
        )
    now = dt.datetime.now(dt.timezone.utc)
    if est_verrouille(responsable, now):
        raise HTTPException(
            status.HTTP_423_LOCKED, "Compte du responsable bloque apres cinq codes faux."
        )
    if not secret_accepte(
        payload.approver_secret, responsable.password_hash, responsable.pin_hash
    ):
        compter_echec(responsable, now)
        await session.commit()
        raise refus
    if not responsable.is_active:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Compte du responsable desactive.")
    if DROIT_REINITIALISER not in permission_codes(responsable):
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            f"{responsable.first_name} {responsable.last_name} n'a pas le droit "
            "de reinitialiser un code.",
        )
    if not agent.is_active:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Compte de l'agent desactive.")

    debloquer(responsable)
    if payload.new_pin is not None:
        agent.pin_hash = hash_secret(payload.new_pin)
    if payload.new_password is not None:
        agent.password_hash = hash_secret(payload.new_password)
        agent.must_change_password = False
    debloquer(agent)
    session.add(
        AuditLog(
            user_id=responsable.id,
            entity_table="users",
            entity_id=agent.id,
            action="RESET_SECRET",
            # Ce qui a change, jamais la valeur.
            after={
                "approved_by": str(responsable.id),
                "pin": payload.new_pin is not None,
                "password": payload.new_password is not None,
            },
            occurred_at=now,
        )
    )
    await session.commit()
    return ResetSecretOut(user_id=agent.id, approved_by=responsable.id)


@router.get("/credentials", response_model=list[CredentialOut])
async def credentials(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
) -> list[User]:
    """Les empreintes des agents de l'hotel, pour la connexion hors ligne.

    Sans elles, un agent cree depuis l'administration ne se connectait qu'en
    ligne, et un code reinitialise sur un poste restait inconnu des autres
    hors ligne. Des empreintes bcrypt, jamais les secrets.

    Ouvert a tout agent connecte : la tablette est partagee, et c'est
    n'importe quel agent qui doit pouvoir s'y connecter pendant une coupure.
    Ce que la tablette garde, elle le garde dans sa base locale -- la meme
    que les clients et les ardoises.
    """
    rows = await session.scalars(
        select(User).where(User.hotel_id == user.hotel_id, User.deleted_at.is_(None))
    )
    return list(rows)
