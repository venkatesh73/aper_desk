defmodule AperDesk.Repo.Migrations.EnableRowLevelSecurity do
  use Ecto.Migration

  @moduledoc """
  Row-level security as defence in depth for multi-tenancy.

  Application-level scoping is still the primary mechanism — every context
  function takes a `Scope` and filters by `studio_id`. But "always remember the
  WHERE clause" is a rule that holds until the one afternoon it does not, and
  the failure mode is showing one studio another studio's clients. RLS turns
  that from a data breach into an empty result set.

  The policy deliberately allows access when `app.studio_id` is unset, so
  migrations, seeds, background reconciliation and the platform-admin console
  keep working. `AperDesk.Repo.with_studio/2` sets it for the duration of a
  transaction; the web and GraphQL layers wrap every tenant request in one.

  Note that a superuser bypasses RLS entirely, which is why the production
  release must connect as a dedicated, non-superuser role.
  """

  @tenant_tables ~w(
    memberships user_invitations contacts leads tags custom_field_definitions
    packages jobs assignments availability_rules booking_slots
    quotes contracts contract_templates
    invoices payments payouts expenses
    galleries gallery_media
    email_accounts email_threads email_messages email_templates
    inbound_captures lead_capture_forms form_submissions notifications
    workflows nurture_sequences outbox_events automation_runs activity_logs
    subscriptions subscription_add_ons studio_usage
    directory_listings portfolio_items reviews studio_categories
  )

  def up do
    for table <- @tenant_tables do
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"

      execute """
      CREATE POLICY #{table}_tenant_isolation ON #{table}
        USING (
          current_setting('app.studio_id', true) IS NULL
          OR current_setting('app.studio_id', true) = ''
          OR studio_id = current_setting('app.studio_id', true)::uuid
        )
        WITH CHECK (
          current_setting('app.studio_id', true) IS NULL
          OR current_setting('app.studio_id', true) = ''
          OR studio_id = current_setting('app.studio_id', true)::uuid
        )
      """
    end
  end

  def down do
    for table <- @tenant_tables do
      execute "DROP POLICY IF EXISTS #{table}_tenant_isolation ON #{table}"
      execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
    end
  end
end
