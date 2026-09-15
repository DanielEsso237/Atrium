"""Modeles SQLAlchemy d'Atrium.

L'import de tous les modules est necessaire pour qu'Alembic voie l'ensemble
des tables dans `Base.metadata` lors de l'autogeneration des migrations.
"""

from app.db.base import Base
from app.models.admin import BusinessDay, Notification, Setting
from app.models.billing import (
    CashSession,
    Folio,
    FolioItem,
    Invoice,
    InvoiceLine,
    Payment,
)
from app.models.core import (
    AuditLog,
    Device,
    Hotel,
    Permission,
    RefreshToken,
    Role,
    RolePermission,
    User,
    UserRole,
)
from app.models.guests import Company, Guest, GuestDocument
from app.models.operations import (
    AmenityConsumption,
    Attachment,
    Equipment,
    HousekeepingTask,
    HousekeepingTaskItem,
    MaintenanceIntervention,
    MaintenanceTicket,
)
from app.models.printing import (
    DocumentTemplate,
    DocumentType,
    Printer,
    PrintJob,
    PrintRoute,
)
from app.models.reservations import (
    Reservation,
    ReservationGuest,
    ReservationRoom,
    Signature,
    StayNight,
)
from app.models.restaurant import (
    MenuCategory,
    MenuItem,
    MenuItemOption,
    Order,
    OrderItem,
    OrderItemOption,
    Outlet,
    PrepStation,
    RestaurantTable,
)
from app.models.rooms import Floor, RatePlan, RatePlanPrice, Room, RoomType, Tax
from app.models.stock import (
    Inventory,
    InventoryLine,
    Product,
    ProductCategory,
    StockLevel,
    StockLocation,
    StockMovement,
    Supplier,
)
from app.models.sync import (
    NumberSequence,
    SyncChangeLog,
    SyncConflict,
    SyncDeviceCursor,
    SyncedTable,
)

__all__ = [
    "Base",
    # Socle
    "Hotel",
    "User",
    "Role",
    "Permission",
    "RolePermission",
    "UserRole",
    "Device",
    "RefreshToken",
    "AuditLog",
    # Chambres
    "Floor",
    "RoomType",
    "Room",
    "RatePlan",
    "RatePlanPrice",
    "Tax",
    # Clients
    "Guest",
    "Company",
    "GuestDocument",
    # Reservations
    "Reservation",
    "ReservationRoom",
    "StayNight",
    "ReservationGuest",
    "Signature",
    # Facturation
    "Folio",
    "FolioItem",
    "Invoice",
    "InvoiceLine",
    "Payment",
    "CashSession",
    # Restauration
    "Outlet",
    "PrepStation",
    "RestaurantTable",
    "MenuCategory",
    "MenuItem",
    "MenuItemOption",
    "Order",
    "OrderItem",
    "OrderItemOption",
    # Housekeeping / maintenance
    "HousekeepingTask",
    "HousekeepingTaskItem",
    "AmenityConsumption",
    "Equipment",
    "MaintenanceTicket",
    "MaintenanceIntervention",
    "Attachment",
    # Stocks
    "ProductCategory",
    "Product",
    "StockLocation",
    "StockLevel",
    "StockMovement",
    "Inventory",
    "InventoryLine",
    "Supplier",
    # Impression
    "Printer",
    "DocumentType",
    "PrintRoute",
    "DocumentTemplate",
    "PrintJob",
    # Synchronisation
    "SyncChangeLog",
    "SyncDeviceCursor",
    "SyncConflict",
    "NumberSequence",
    "SyncedTable",
    # Administration
    "Setting",
    "BusinessDay",
    "Notification",
]
