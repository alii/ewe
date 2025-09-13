ifneq (,$(wildcard ./.env))
    include .env
    export
endif

ENV_VARS = PG_DATABASE=$(PG_DATABASE) PG_PASSWORD=$(PG_PASSWORD) PG_USER=$(PG_USER) PG_PORT=$(PG_PORT) DATABASE_URL=$(DATABASE_URL) APP_PORT=$(APP_PORT) JWT_SECRET=$(JWT_SECRET)

squirrel:
	$(ENV_VARS) gleam run -m squirrel

start:
	$(ENV_VARS) gleam run

tests:
	$(ENV_VARS) gleam test