# NPM High Availability Cluster Playbook

This playbook configures a 2-node High Availability cluster using Pacemaker, Corosync, and DRBD to manage a Docker Compose stack (Nginx Proxy Manager).

## Prerequisites
1. DRBD block devices (`/dev/drbd10`, `/dev/drbd11`) must be initialized and synced before running the pacemaker resource creation tasks.
2. The `docker-compose.yml` must exist in `/srv/npm/compose/`.

## Execution
```bash
ansible-playbook main.yml --ask-vault-pass
