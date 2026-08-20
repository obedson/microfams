-- ESC-07: reject escrow release requests that exceed the remaining held amount.
SET search_path=public,extensions;
CREATE OR REPLACE FUNCTION enforce_escrow_release_remaining() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,extensions AS $$
DECLARE c escrow_contracts;
BEGIN
 SELECT * INTO c FROM escrow_contracts WHERE id=NEW.contract_id AND organization_id=NEW.organization_id FOR UPDATE;
 IF c.id IS NULL OR c.released_minor + NEW.amount_minor > c.amount_minor THEN
   RAISE EXCEPTION 'Escrow release exceeds remaining held amount';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER escrow_release_remaining_guard BEFORE INSERT ON escrow_release_requests FOR EACH ROW EXECUTE FUNCTION enforce_escrow_release_remaining();
