-- GT-10L approved shared-asset journal mapping contract.
-- This catalogue defines posting inputs only; disposal and transfer execution remain disabled.
SET search_path=public,extensions;

INSERT INTO financial_account_purpose_rules(
  purpose,account_class,normal_side,allowed_owner_types,is_control
) VALUES
 ('operating_cash','asset','debit',ARRAY['organization','system'],TRUE),
 ('shared_asset_cost','asset','debit',ARRAY['group'],TRUE),
 ('accumulated_depreciation','asset','credit',ARRAY['group'],TRUE),
 ('asset_sale_receivable','asset','debit',ARRAY['organization','group'],TRUE),
 ('asset_disposal_gain','revenue','credit',ARRAY['organization','group'],FALSE),
 ('asset_disposal_loss','expense','debit',ARRAY['organization','group'],FALSE)
ON CONFLICT (purpose) DO NOTHING;

CREATE TABLE IF NOT EXISTS group_asset_journal_mappings (
 mapping_key TEXT NOT NULL CHECK(mapping_key IN(
   'disposal_with_proceeds','disposal_without_proceeds','book_value_transfer'
 )),
 version INTEGER NOT NULL CHECK(version>0),
 accounting_basis TEXT NOT NULL CHECK(accounting_basis IN('carrying_value','book_value_no_gain_loss')),
 required_facts TEXT[] NOT NULL CHECK(cardinality(required_facts)>0),
 execution_enabled BOOLEAN NOT NULL DEFAULT FALSE,
 approval_reference TEXT NOT NULL CHECK(char_length(trim(approval_reference)) BETWEEN 8 AND 160),
 effective_from DATE NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 PRIMARY KEY(mapping_key,version),
 CONSTRAINT group_asset_journal_execution_disabled CHECK(execution_enabled=FALSE)
);

CREATE TABLE IF NOT EXISTS group_asset_journal_mapping_lines (
 mapping_key TEXT NOT NULL,
 mapping_version INTEGER NOT NULL,
 line_number INTEGER NOT NULL CHECK(line_number>0),
 line_role TEXT NOT NULL CHECK(line_role~'^[a-z][a-z0-9_]{1,63}$'),
 side TEXT NOT NULL CHECK(side IN('debit','credit')),
 amount_source TEXT NOT NULL CHECK(amount_source IN(
   'proceeds_minor','accumulated_depreciation_minor','disposal_loss_minor',
   'disposal_gain_minor','original_cost_minor'
 )),
 conditional_when_zero BOOLEAN NOT NULL DEFAULT FALSE,
 PRIMARY KEY(mapping_key,mapping_version,line_number),
 UNIQUE(mapping_key,mapping_version,line_role),
 FOREIGN KEY(mapping_key,mapping_version)
   REFERENCES group_asset_journal_mappings(mapping_key,version)
);

CREATE TABLE IF NOT EXISTS group_asset_journal_line_purposes (
 mapping_key TEXT NOT NULL,
 mapping_version INTEGER NOT NULL,
 line_number INTEGER NOT NULL,
 purpose TEXT NOT NULL REFERENCES financial_account_purpose_rules(purpose),
 PRIMARY KEY(mapping_key,mapping_version,line_number,purpose),
 FOREIGN KEY(mapping_key,mapping_version,line_number)
   REFERENCES group_asset_journal_mapping_lines(mapping_key,mapping_version,line_number)
);

INSERT INTO group_asset_journal_mappings(
 mapping_key,version,accounting_basis,required_facts,execution_enabled,approval_reference,effective_from
) VALUES
 ('disposal_with_proceeds',1,'carrying_value',ARRAY[
   'currency','original_cost_minor','cost_ledger_source','accumulated_depreciation_minor',
   'depreciation_ledger_source','carrying_value_minor','proceeds_minor','proceeds_evidence',
   'effective_date','accounting_period_id','maker_id','checker_id','reconciliation_status'
 ],FALSE,'GT-10-asset-accounting-v1',DATE '2026-08-16'),
 ('disposal_without_proceeds',1,'carrying_value',ARRAY[
   'currency','original_cost_minor','cost_ledger_source','accumulated_depreciation_minor',
   'depreciation_ledger_source','carrying_value_minor','effective_date','accounting_period_id',
   'maker_id','checker_id','reconciliation_status'
 ],FALSE,'GT-10-asset-accounting-v1',DATE '2026-08-16'),
 ('book_value_transfer',1,'book_value_no_gain_loss',ARRAY[
   'currency','original_cost_minor','cost_ledger_source','accumulated_depreciation_minor',
   'depreciation_ledger_source','carrying_value_minor','source_group_id','destination_group_id',
   'destination_acceptance_evidence','effective_date','accounting_period_id','maker_id','checker_id',
   'reconciliation_status'
 ],FALSE,'GT-10-asset-accounting-v1',DATE '2026-08-16')
ON CONFLICT (mapping_key,version) DO NOTHING;

INSERT INTO group_asset_journal_mapping_lines(
 mapping_key,mapping_version,line_number,line_role,side,amount_source,conditional_when_zero
) VALUES
 ('disposal_with_proceeds',1,1,'proceeds','debit','proceeds_minor',FALSE),
 ('disposal_with_proceeds',1,2,'accumulated_depreciation','debit','accumulated_depreciation_minor',TRUE),
 ('disposal_with_proceeds',1,3,'disposal_loss','debit','disposal_loss_minor',TRUE),
 ('disposal_with_proceeds',1,4,'disposal_gain','credit','disposal_gain_minor',TRUE),
 ('disposal_with_proceeds',1,5,'asset_cost','credit','original_cost_minor',FALSE),
 ('disposal_without_proceeds',1,1,'accumulated_depreciation','debit','accumulated_depreciation_minor',TRUE),
 ('disposal_without_proceeds',1,2,'disposal_loss','debit','disposal_loss_minor',TRUE),
 ('disposal_without_proceeds',1,3,'asset_cost','credit','original_cost_minor',FALSE),
 ('book_value_transfer',1,1,'source_accumulated_depreciation','debit','accumulated_depreciation_minor',TRUE),
 ('book_value_transfer',1,2,'destination_asset_cost','debit','original_cost_minor',FALSE),
 ('book_value_transfer',1,3,'source_asset_cost','credit','original_cost_minor',FALSE),
 ('book_value_transfer',1,4,'destination_accumulated_depreciation','credit','accumulated_depreciation_minor',TRUE)
ON CONFLICT (mapping_key,mapping_version,line_number) DO NOTHING;

INSERT INTO group_asset_journal_line_purposes(mapping_key,mapping_version,line_number,purpose) VALUES
 ('disposal_with_proceeds',1,1,'operating_cash'),
 ('disposal_with_proceeds',1,1,'asset_sale_receivable'),
 ('disposal_with_proceeds',1,2,'accumulated_depreciation'),
 ('disposal_with_proceeds',1,3,'asset_disposal_loss'),
 ('disposal_with_proceeds',1,4,'asset_disposal_gain'),
 ('disposal_with_proceeds',1,5,'shared_asset_cost'),
 ('disposal_without_proceeds',1,1,'accumulated_depreciation'),
 ('disposal_without_proceeds',1,2,'asset_disposal_loss'),
 ('disposal_without_proceeds',1,3,'shared_asset_cost'),
 ('book_value_transfer',1,1,'accumulated_depreciation'),
 ('book_value_transfer',1,2,'shared_asset_cost'),
 ('book_value_transfer',1,3,'shared_asset_cost'),
 ('book_value_transfer',1,4,'accumulated_depreciation')
ON CONFLICT DO NOTHING;

REVOKE ALL ON group_asset_journal_mappings,group_asset_journal_mapping_lines,group_asset_journal_line_purposes FROM PUBLIC,anon,authenticated;
GRANT SELECT ON group_asset_journal_mappings,group_asset_journal_mapping_lines,group_asset_journal_line_purposes TO service_role;
REVOKE INSERT,UPDATE,DELETE ON group_asset_journal_mappings,group_asset_journal_mapping_lines,group_asset_journal_line_purposes FROM service_role;
