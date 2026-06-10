# Backlog

## cert_manager — scheduled auto-renewal

Schedule `cert_manager.yml` to run automatically (cron or Ansible scheduled task) so
wildcard certs renew before expiry without manual intervention. Currently runs on demand only.

Priority: low — acme.sh certs have 90-day validity, plenty of lead time.
