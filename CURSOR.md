## Cursor Cloud specific instructions

### System dependencies (pre-installed in snapshot)

- **Ruby 4.0.1** at `/usr/local/ruby-4.0.1/bin` (built from source via ruby-build)
- **Bun 1.3.9** at `/home/ubuntu/.bun/bin`
- **PostgreSQL 18** with pgvector extension (apt: `postgresql-18`, `postgresql-18-pgvector`)
- **libvips** for image processing
- Both Ruby and Bun are on PATH via `~/.bashrc`

### Starting PostgreSQL

PostgreSQL does not auto-start. Before running the app or tests:

```bash
sudo pg_ctlcluster 18 main start
```

### Running the application

Standard commands per the Development Commands section above. Use `bin/dev` (Foreman: Puma + Solid Queue + Bun watchers) for the full dev experience, or `bin/rails server` for just the web server.
