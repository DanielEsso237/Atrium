"""Facturation et caisse : folios, charges, factures, encaissements, shifts."""

from __future__ import annotations

import datetime as dt
import uuid

from sqlalchemy import (
    BigInteger,
    Boolean,
    Date,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import HotelScoped, SyncBase
from app.models.enums import (
    CashSessionStatus,
    ChargeCategory,
    FolioStatus,
    FolioType,
    InvoiceStatus,
    PaymentMethod,
)
from app.models.rooms import _enum


class Folio(SyncBase, HotelScoped):
    """Compte client : le centre de gravite de toute la facturation.

    Chaque charge du systeme -- nuitee, addition du restaurant, minibar, spa --
    atterrit dans `folio_items`. La facture n'est ensuite qu'un gel du folio a
    un instant donne.

    C'est ce decouplage qui rend possibles la facture provisoire en cours de
    sejour, la facture partielle, et l'eclatement d'un compte entre le client
    et sa societe, sans jamais retoucher les charges d'origine. C'est aussi ce
    qui rend F3.6 trivial : un report en chambre est une charge sur le folio de
    la chambre, un paiement direct est un folio de type TABLE ouvert et solde
    dans la foulee.
    """

    __tablename__ = "folios"
    __table_args__ = (
        UniqueConstraint("hotel_id", "number"),
        Index("ix_folios_status", "status"),
    )

    number: Mapped[str] = mapped_column(String(32))
    type: Mapped[FolioType] = mapped_column(
        _enum(FolioType, "folio_type"), default=FolioType.GUEST
    )
    status: Mapped[FolioStatus] = mapped_column(
        _enum(FolioStatus, "folio_status"), default=FolioStatus.OPEN
    )

    reservation_room_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("reservation_rooms.id", ondelete="SET NULL"),
        default=None,
        index=True,
    )
    guest_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("guests.id", ondelete="SET NULL"), default=None, index=True
    )
    company_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("companies.id", ondelete="SET NULL"), default=None, index=True
    )
    restaurant_table_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("restaurant_tables.id", ondelete="SET NULL"), default=None
    )

    # Totaux tenus a jour a chaque ecriture. Redondants avec la somme des
    # lignes, mais une tablette doit afficher un solde instantanement sans
    # agreger l'historique du folio a chaque rafraichissement d'ecran.
    charges_total: Mapped[int] = mapped_column(BigInteger, default=0)
    payments_total: Mapped[int] = mapped_column(BigInteger, default=0)
    balance: Mapped[int] = mapped_column(BigInteger, default=0)

    opened_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    closed_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    notes: Mapped[str | None] = mapped_column(Text, default=None)

    items: Mapped[list[FolioItem]] = relationship(
        back_populates="folio", lazy="selectin"
    )


class FolioItem(SyncBase):
    """Une charge portee au compte du client.

    Le couple (`source_table`, `source_id`) remonte a l'origine de la charge --
    une commande au restaurant, une nuitee, une intervention -- ce qui permet
    de justifier chaque ligne de facture et de retrouver qui a consomme quoi.

    Une charge ne se supprime jamais : on l'annule (`is_void`) avec un motif.
    Une suppression pure casserait la piste d'audit exigee au paragraphe 6.2 et
    ne se propagerait pas correctement vers les tablettes hors ligne.
    """

    __tablename__ = "folio_items"
    __table_args__ = (
        Index("ix_folio_items_business_date", "business_date"),
        Index("ix_folio_items_source", "source_table", "source_id"),
    )

    folio_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("folios.id", ondelete="CASCADE"), index=True
    )
    category: Mapped[ChargeCategory] = mapped_column(
        _enum(ChargeCategory, "charge_category")
    )
    label: Mapped[str] = mapped_column(String(160))
    quantity: Mapped[int] = mapped_column(Integer, default=1)
    unit_price: Mapped[int] = mapped_column(BigInteger, default=0)
    amount: Mapped[int] = mapped_column(BigInteger, default=0)
    tax_amount: Mapped[int] = mapped_column(BigInteger, default=0)
    tax_rate: Mapped[int] = mapped_column(Integer, default=0)
    business_date: Mapped[dt.date] = mapped_column(Date)

    source_table: Mapped[str | None] = mapped_column(String(64), default=None)
    source_id: Mapped[uuid.UUID | None] = mapped_column(default=None)

    posted_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
    posted_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    is_void: Mapped[bool] = mapped_column(Boolean, default=False)
    void_reason: Mapped[str | None] = mapped_column(String(255), default=None)
    voided_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )

    folio: Mapped[Folio] = relationship(back_populates="items")


class Invoice(SyncBase, HotelScoped):
    """Facture : gel du folio a un instant donne (F1.4).

    Point de conception dicte par le mode hors ligne : une facture emise sans
    reseau est marquee `is_provisional` et ne porte pas de numero legal. Le
    numero sequentiel est attribue par le serveur a la synchronisation, via
    `number_sequences`.

    Une numerotation legale doit etre continue et sans trou ; aucune tablette
    isolee ne peut garantir cela seule. Le client recoit donc un document
    provisoire clairement identifie, et la facture definitive suit.
    """

    __tablename__ = "invoices"
    __table_args__ = (
        UniqueConstraint("hotel_id", "number"),
        Index("ix_invoices_issued_at", "issued_at"),
        Index("ix_invoices_status", "status"),
    )

    # Nul tant que le serveur n'a pas attribue le numero definitif.
    number: Mapped[str | None] = mapped_column(String(32), default=None)
    provisional_number: Mapped[str | None] = mapped_column(String(40), default=None)
    is_provisional: Mapped[bool] = mapped_column(Boolean, default=False)

    folio_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("folios.id", ondelete="RESTRICT"), index=True
    )
    guest_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("guests.id", ondelete="SET NULL"), default=None
    )
    company_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("companies.id", ondelete="SET NULL"), default=None
    )

    status: Mapped[InvoiceStatus] = mapped_column(
        _enum(InvoiceStatus, "invoice_status"), default=InvoiceStatus.DRAFT
    )
    issued_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    due_date: Mapped[dt.date | None] = mapped_column(Date, default=None)

    subtotal: Mapped[int] = mapped_column(BigInteger, default=0)
    discount_total: Mapped[int] = mapped_column(BigInteger, default=0)
    tax_total: Mapped[int] = mapped_column(BigInteger, default=0)
    total: Mapped[int] = mapped_column(BigInteger, default=0)
    currency: Mapped[str] = mapped_column(String(8), default="XOF")

    # Identite du destinataire figee a l'emission : si le client change
    # d'adresse l'annee suivante, la facture deja emise ne doit pas changer.
    bill_to_name: Mapped[str | None] = mapped_column(String(160), default=None)
    bill_to_address: Mapped[str | None] = mapped_column(String(255), default=None)
    bill_to_tax_id: Mapped[str | None] = mapped_column(String(40), default=None)

    pdf_path: Mapped[str | None] = mapped_column(String(255), default=None)
    cancelled_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    cancel_reason: Mapped[str | None] = mapped_column(String(255), default=None)

    lines: Mapped[list[InvoiceLine]] = relationship(
        back_populates="invoice", lazy="selectin"
    )


class InvoiceLine(SyncBase):
    __tablename__ = "invoice_lines"

    invoice_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("invoices.id", ondelete="CASCADE"), index=True
    )
    folio_item_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("folio_items.id", ondelete="SET NULL"), default=None
    )
    label: Mapped[str] = mapped_column(String(160))
    quantity: Mapped[int] = mapped_column(Integer, default=1)
    unit_price: Mapped[int] = mapped_column(BigInteger, default=0)
    tax_rate: Mapped[int] = mapped_column(Integer, default=0)
    tax_amount: Mapped[int] = mapped_column(BigInteger, default=0)
    amount: Mapped[int] = mapped_column(BigInteger, default=0)
    sort_order: Mapped[int] = mapped_column(default=0)

    invoice: Mapped[Invoice] = relationship(back_populates="lines")


class CashSession(SyncBase, HotelScoped):
    """Shift de caisse : ouverture, encaissements, fermeture, ecart.

    Le cahier des charges liste un document "Rapport de shift" dans la matrice
    d'impression (paragraphe 4.2) sans prevoir la donnee correspondante. Cette
    table la fournit : les encaissements s'y rattachent par
    `payments.cash_session_id`, et l'ecart de caisse se calcule a la fermeture.
    """

    __tablename__ = "cash_sessions"
    __table_args__ = (Index("ix_cash_sessions_user_status", "user_id", "status"),)

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT")
    )
    device_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("devices.id", ondelete="SET NULL"), default=None
    )
    status: Mapped[CashSessionStatus] = mapped_column(
        _enum(CashSessionStatus, "cash_session_status"), default=CashSessionStatus.OPEN
    )
    opened_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    opening_float: Mapped[int] = mapped_column(BigInteger, default=0)
    closed_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    # Montant compte physiquement par le caissier a la fermeture.
    counted_amount: Mapped[int | None] = mapped_column(BigInteger, default=None)
    # Montant attendu d'apres les encaissements enregistres.
    expected_amount: Mapped[int] = mapped_column(BigInteger, default=0)
    variance: Mapped[int] = mapped_column(BigInteger, default=0)
    notes: Mapped[str | None] = mapped_column(Text, default=None)


class Payment(SyncBase, HotelScoped):
    """Encaissement ou remboursement (F1.4)."""

    __tablename__ = "payments"
    __table_args__ = (
        Index("ix_payments_received_at", "received_at"),
        Index("ix_payments_method", "method"),
    )

    folio_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("folios.id", ondelete="SET NULL"), default=None, index=True
    )
    invoice_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("invoices.id", ondelete="SET NULL"), default=None, index=True
    )
    cash_session_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("cash_sessions.id", ondelete="SET NULL"), default=None, index=True
    )

    method: Mapped[PaymentMethod] = mapped_column(
        _enum(PaymentMethod, "payment_method")
    )
    amount: Mapped[int] = mapped_column(BigInteger)
    currency: Mapped[str] = mapped_column(String(8), default="XOF")
    # Reference externe : numero de transaction carte, identifiant Mobile Money,
    # reference de virement. Indispensable pour un rapprochement bancaire.
    reference: Mapped[str | None] = mapped_column(String(80), default=None)
    received_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
    received_at: Mapped[dt.datetime | None] = mapped_column(default=None)
    business_date: Mapped[dt.date | None] = mapped_column(Date, default=None)
    is_refund: Mapped[bool] = mapped_column(Boolean, default=False)
    notes: Mapped[str | None] = mapped_column(String(255), default=None)
