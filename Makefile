SHELL := /bin/bash
include .env
export

.PHONY: help db-up db-down db-logs migrate migrate-new migrate-rollback migrate-status sqlgen sqlcheck run test coverage build deps

help:
	@echo "db-up            Start Postgres in Docker"
	@echo "db-down          Stop Postgres"
	@echo "db-logs          Tail Postgres logs"
	@echo "migrate          Apply all pending migrations"
	@echo "migrate-new      Create migration (NAME=add_foo)"
	@echo "migrate-rollback Roll back last migration"
	@echo "migrate-status   Show migration state"
	@echo "sqlgen           Generate typed SQL modules"
	@echo "sqlcheck         Verify generated SQL is up to date"
	@echo "run              Run the app"
	@echo "test             Run tests"
	@echo "coverage         Run tests under cover, print coverage summary"
	@echo "build            Build the project"
	@echo "deps             Fetch deps"

db-up:
	docker compose up -d postgres

db-down:
	docker compose down

db-logs:
	docker compose logs -f postgres

migrate:
	gleam run -m cigogne all

migrate-new:
	gleam run -m cigogne -- new --name $(NAME)

migrate-rollback:
	gleam run -m cigogne down

migrate-status:
	gleam run -m cigogne show

sqlgen:
	gleam run -m squirrel_db

sqlcheck:
	gleam run -m squirrel_db -- check

run:
	gleam run

test:
	gleam test

coverage:
	./bin/coverage

build:
	gleam build

deps:
	gleam deps download
