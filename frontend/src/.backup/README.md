# Backup Files

This folder contains old versions of files before redesign.

**Files:**
- `MyBookings_OLD.tsx` - Original farmer booking dashboard (replaced 2026-03-06)
- `OwnerBookings_OLD.tsx` - Original owner booking dashboard (replaced 2026-03-06)

**Safe to delete after:** Testing confirms new versions work correctly (recommend 1-2 weeks)

**To restore (if needed):**
```bash
mv frontend/src/.backup/MyBookings_OLD.tsx frontend/src/pages/MyBookings.tsx
mv frontend/src/.backup/OwnerBookings_OLD.tsx frontend/src/pages/OwnerBookings.tsx
```
