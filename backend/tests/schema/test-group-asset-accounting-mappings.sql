DO $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM financial_account_purpose_rules WHERE purpose='shared_asset_cost' AND account_class='asset' AND normal_side='debit' AND allowed_owner_types=ARRAY['group'] AND is_control) THEN RAISE EXCEPTION 'shared asset cost purpose is invalid'; END IF;
 IF NOT EXISTS(SELECT 1 FROM financial_account_purpose_rules WHERE purpose='accumulated_depreciation' AND account_class='asset' AND normal_side='credit' AND allowed_owner_types=ARRAY['group'] AND is_control) THEN RAISE EXCEPTION 'accumulated depreciation purpose is invalid'; END IF;
 IF NOT EXISTS(SELECT 1 FROM financial_account_purpose_rules WHERE purpose='asset_sale_receivable' AND account_class='asset' AND normal_side='debit') THEN RAISE EXCEPTION 'asset sale receivable purpose is invalid'; END IF;
 IF NOT EXISTS(SELECT 1 FROM financial_account_purpose_rules WHERE purpose='asset_disposal_gain' AND account_class='revenue' AND normal_side='credit') THEN RAISE EXCEPTION 'asset disposal gain purpose is invalid'; END IF;
 IF NOT EXISTS(SELECT 1 FROM financial_account_purpose_rules WHERE purpose='asset_disposal_loss' AND account_class='expense' AND normal_side='debit') THEN RAISE EXCEPTION 'asset disposal loss purpose is invalid'; END IF;
 IF EXISTS(SELECT 1 FROM financial_account_purpose_rules WHERE purpose='transfer_clearing') THEN RAISE EXCEPTION 'book-value transfer unexpectedly provisions clearing'; END IF;

 IF (SELECT count(*) FROM group_asset_journal_mappings)<>3
  OR NOT EXISTS(SELECT 1 FROM group_asset_journal_mappings WHERE mapping_key IN('disposal_with_proceeds','disposal_without_proceeds') AND execution_enabled GROUP BY version HAVING count(*)=2)
  OR NOT EXISTS(SELECT 1 FROM group_asset_journal_mappings WHERE mapping_key='book_value_transfer' AND execution_enabled) THEN RAISE EXCEPTION 'approved mapping execution state is invalid'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_asset_journal_mappings WHERE mapping_key='book_value_transfer' AND version=1 AND accounting_basis='book_value_no_gain_loss' AND required_facts@>ARRAY['source_group_id','destination_group_id','destination_acceptance_evidence','carrying_value_minor']) THEN RAISE EXCEPTION 'book-value transfer contract is invalid'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_asset_journal_mappings WHERE mapping_key='disposal_with_proceeds' AND required_facts@>ARRAY['proceeds_minor','proceeds_evidence','cost_ledger_source','depreciation_ledger_source']) THEN RAISE EXCEPTION 'disposal proceeds facts are incomplete'; END IF;
 IF NOT EXISTS(SELECT 1 FROM group_asset_journal_mappings WHERE mapping_key='disposal_without_proceeds' AND NOT required_facts@>ARRAY['proceeds_minor']) THEN RAISE EXCEPTION 'zero-proceeds disposal contract is invalid'; END IF;

 IF (SELECT count(*) FROM group_asset_journal_mapping_lines)<>12 OR (SELECT count(*) FROM group_asset_journal_line_purposes)<>13 THEN RAISE EXCEPTION 'mapping line catalogue is incomplete'; END IF;
 IF NOT EXISTS(
  SELECT 1 FROM group_asset_journal_mapping_lines l
  JOIN group_asset_journal_line_purposes p USING(mapping_key,mapping_version,line_number)
  WHERE l.mapping_key='disposal_with_proceeds' AND l.line_role='proceeds' AND l.side='debit' AND l.amount_source='proceeds_minor' AND p.purpose='operating_cash'
 ) OR NOT EXISTS(
  SELECT 1 FROM group_asset_journal_mapping_lines l
  JOIN group_asset_journal_line_purposes p USING(mapping_key,mapping_version,line_number)
  WHERE l.mapping_key='disposal_with_proceeds' AND l.line_role='proceeds' AND p.purpose='asset_sale_receivable'
 ) THEN RAISE EXCEPTION 'disposal proceeds debit mapping is invalid'; END IF;
 IF NOT EXISTS(
  SELECT 1 FROM group_asset_journal_mapping_lines l
  JOIN group_asset_journal_line_purposes p USING(mapping_key,mapping_version,line_number)
  WHERE l.mapping_key='disposal_with_proceeds' AND l.line_role='asset_cost' AND l.side='credit' AND p.purpose='shared_asset_cost'
 ) OR NOT EXISTS(
  SELECT 1 FROM group_asset_journal_mapping_lines l
  JOIN group_asset_journal_line_purposes p USING(mapping_key,mapping_version,line_number)
  WHERE l.mapping_key='disposal_with_proceeds' AND l.line_role='disposal_gain' AND l.side='credit' AND p.purpose='asset_disposal_gain'
 ) OR NOT EXISTS(
  SELECT 1 FROM group_asset_journal_mapping_lines l
  JOIN group_asset_journal_line_purposes p USING(mapping_key,mapping_version,line_number)
  WHERE l.mapping_key='disposal_with_proceeds' AND l.line_role='disposal_loss' AND l.side='debit' AND p.purpose='asset_disposal_loss'
 ) THEN RAISE EXCEPTION 'disposal carrying-value mapping is invalid'; END IF;
 IF NOT EXISTS(
  SELECT 1 FROM group_asset_journal_mapping_lines l
  WHERE l.mapping_key='book_value_transfer' AND l.line_role='source_accumulated_depreciation' AND l.side='debit'
 ) OR NOT EXISTS(
  SELECT 1 FROM group_asset_journal_mapping_lines l
  WHERE l.mapping_key='book_value_transfer' AND l.line_role='destination_asset_cost' AND l.side='debit'
 ) OR NOT EXISTS(
  SELECT 1 FROM group_asset_journal_mapping_lines l
  WHERE l.mapping_key='book_value_transfer' AND l.line_role='source_asset_cost' AND l.side='credit'
 ) OR NOT EXISTS(
  SELECT 1 FROM group_asset_journal_mapping_lines l
  WHERE l.mapping_key='book_value_transfer' AND l.line_role='destination_accumulated_depreciation' AND l.side='credit'
 ) THEN RAISE EXCEPTION 'book-value transfer line directions are invalid'; END IF;
 IF has_table_privilege('service_role','group_asset_journal_mappings','INSERT') OR has_table_privilege('service_role','group_asset_journal_mapping_lines','UPDATE') OR has_table_privilege('service_role','group_asset_journal_line_purposes','DELETE') THEN RAISE EXCEPTION 'service role can mutate approved journal mappings'; END IF;
END $$;
SELECT 'group asset accounting mapping schema tests passed' AS result;
