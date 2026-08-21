# Farm Record Property Linkage

Generic farm-record updates cannot change `property_id`. Property linkage is established from a tenant- and farmer-validated booking, which writes both the booking and its property together.

This is an application-only change with no migration. Roll back by redeploying the previous backend revision; do not manually alter record ownership or property data.
