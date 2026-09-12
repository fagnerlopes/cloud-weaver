-- Hermes Agent database bootstrap.
-- Runs on the first boot of the postgres container, executed by the
-- POSTGRES_USER superuser. Creates a dedicated database for the WAHA
-- external storage integration (enabled later if the recipe is upgraded).
CREATE DATABASE waha;