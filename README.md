# networth

Учёт личных финансов с несколькими пользователями и финансовыми пространствами (workspaces). В основе — ledger с двойной записью: каждая операция создаёт сбалансированные неизменяемые проводки, балансы считаются из проводок.

**Границы.** Приложение учитывает деньги, а не двигает их: нет подключения к банкам, нет загрузки курсов и автоматической конвертации валют. Отрицательный баланс допустим. AI-ввод, когда появится, будет отдельным клиентом ядра (DECISIONS 19).

## Репозиторий

```
server/              JSON API на Elixir — запуск, API, код: server/README.md
docs/                общая документация продукта
docker-compose.yml   PostgreSQL 18 для разработки
AGENTS.md            правила работы в репозитории (CLAUDE.md импортирует его)
```

Веб-клиент появится рядом, в `web/`.

## Документация

- [server/README.md](server/README.md) — запуск сервера, окружение, HTTP API, раскладка кода
- [docs/DOMAIN.md](docs/DOMAIN.md) — доменная и финансовая модель, инварианты, примеры проводок
- [docs/DECISIONS.md](docs/DECISIONS.md) — журнал решений и альтернатив
- [docs/ROADMAP.md](docs/ROADMAP.md) — что сделано, что дальше, ограничения
- Схема БД — в `server/priv/migrations/*.sql`

## Быстрый старт

```sh
docker compose up -d --wait      # PostgreSQL
cd server
mix deps.get
mix db.setup && mix db.seed      # база и демо-данные: demo@networth.local / demo-password
mix run --no-halt                # API на http://localhost:4000
```
