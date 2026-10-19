-- Insert before the new additive farm migrations, in disposable PostgreSQL only.
INSERT INTO users(id,email,password,name,role) VALUES
('62000000-0000-4000-8000-000000000001','farm-upgrade@example.test','synthetic-unused-password','Legacy Farm Owner','farmer')
ON CONFLICT (id) DO NOTHING;

INSERT INTO farm_records(id,organization_id,farmer_id,livestock_type,livestock_count,feed_consumption,mortality_count,expenses,record_date)
VALUES('62000000-0000-4000-8000-000000000002','62000000-0000-4000-8000-000000000001','62000000-0000-4000-8000-000000000001','goat',10,2,1,500,CURRENT_DATE)
ON CONFLICT (id) DO NOTHING;