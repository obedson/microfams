BEGIN;
-- Shared inventory command needed by farm input/production integration.
-- Uses the existing item and movement ledger; does not create another ledger.
CREATE OR REPLACE FUNCTION apply_inventory_movement(p_organization UUID,p_item UUID,p_quantity BIGINT,p_reason TEXT,p_key TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE item inventory_items; prior inventory_movements;
BEGIN
 IF p_quantity IS NULL OR p_quantity=0 OR length(btrim(p_reason))=0 OR length(p_key) NOT BETWEEN 1 AND 160
 THEN RAISE EXCEPTION 'INVENTORY_MOVEMENT_INVALID'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_organization::TEXT||':'||p_key,19));
 SELECT * INTO item FROM inventory_items WHERE id=p_item AND organization_id=p_organization FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_ITEM_NOT_FOUND'; END IF;
 SELECT * INTO prior FROM inventory_movements WHERE organization_id=p_organization AND idempotency_key=p_key;
 IF FOUND THEN
  IF prior.item_id<>p_item OR prior.quantity_minor<>p_quantity OR prior.reason<>btrim(p_reason) THEN RAISE EXCEPTION 'INVENTORY_IDEMPOTENCY_CONFLICT'; END IF;
  RETURN to_jsonb(item);
 END IF;
 IF item.quantity_minor+p_quantity<0 THEN RAISE EXCEPTION 'INVENTORY_QUANTITY_NEGATIVE'; END IF;
 INSERT INTO inventory_movements(organization_id,item_id,quantity_minor,reason,idempotency_key)
 VALUES(p_organization,p_item,p_quantity,btrim(p_reason),p_key);
 UPDATE inventory_items SET quantity_minor=quantity_minor+p_quantity,updated_at=now() WHERE id=p_item RETURNING * INTO item;
 RETURN to_jsonb(item);
END $$;
REVOKE ALL ON FUNCTION apply_inventory_movement(UUID,UUID,BIGINT,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION apply_inventory_movement(UUID,UUID,BIGINT,TEXT,TEXT) TO service_role;
COMMIT;