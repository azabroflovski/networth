# networth

Учёт личных финансов с несколькими пользователями и финансовыми пространствами (workspaces). В основе — ledger с двойной записью: каждая операция создаёт сбалансированные неизменяемые проводки, балансы считаются из проводок.

Сейчас это JSON API без UI.

**Границы.** Приложение учитывает деньги, а не двигает их: нет подключения к банкам, нет загрузки курсов и автоматической конвертации валют. Отрицательный баланс допустим. AI-ввод, когда появится, будет отдельным клиентом ядра (DECISIONS 19).

## Документация

- [AGENTS.md](AGENTS.md) — правила работы в репозитории (CLAUDE.md импортирует его)
- [docs/DOMAIN.md](docs/DOMAIN.md) — доменная и финансовая модель, инварианты, примеры проводок
- [docs/DECISIONS.md](docs/DECISIONS.md) — принятые решения и альтернативы
- [docs/ROADMAP.md](docs/ROADMAP.md) — что сделано, что дальше, ограничения
- Схема БД — в `priv/migrations/*.sql`, отдельного описания нет

## Стек

- Elixir 1.18+ / OTP 26+ (разработка на Elixir 1.20, OTP 28)
- HTTP: Plug + Bandit
- PostgreSQL 18+ (первичные ключи `DEFAULT uuidv7()`)
- Доступ к БД: Postgrex и явный SQL
- JSON: Jason; Decimal — только для курса обмена
- Тесты: ExUnit на реальной PostgreSQL

## Запуск

Нужна PostgreSQL 18. Проще всего поднять её из `docker-compose.yml` (данные хранятся в томе `postgres-data`):

```sh
docker compose up -d --wait
```

Можно использовать и свою PostgreSQL: по умолчанию приложение ходит на `postgres:postgres@localhost:5432`. Если порт 5432 занят, контейнер можно поднять на другом (`POSTGRES_PORT=55432 docker compose up -d --wait`) и указать его в `DATABASE_URL` / `TEST_DATABASE_URL`.

```sh
mix deps.get
mix db.setup          # создать БД networth_dev и применить миграции
mix run --no-halt     # API на http://localhost:4000
```

```sh
curl -s -XPOST localhost:4000/api/register -H 'content-type: application/json' \
  -d '{"email":"me@example.com","name":"Me","password":"password123"}'
# -> {"token": "...", "workspace": {"id": "01a1c776-...", ...}, ...}

curl -s -XPOST localhost:4000/api/workspaces/$WORKSPACE_ID/accounts \
  -H 'content-type: application/json' -H "authorization: Bearer $TOKEN" \
  -d '{"name":"Наличные","type":"cash","currency":"UZS","opening_balance":"1000000"}'
```

## Окружение

| Переменная | Назначение | По умолчанию |
|---|---|---|
| `DATABASE_URL` | БД для dev/prod | dev: `postgres://postgres:postgres@localhost:5432/networth_dev`, prod: обязательна |
| `TEST_DATABASE_URL` | БД для тестов | `postgres://postgres:postgres@localhost:5432/networth_test` |
| `PORT` | порт HTTP | `4000` |
| `POOL_SIZE` | размер пула соединений | `10` |

У тестов отдельная переменная, чтобы `DATABASE_URL` не мог направить их на рабочую базу (тесты делают `TRUNCATE`).

## Задачи mix и тесты

| Команда | Что делает |
|---|---|
| `mix db.create` | создаёт БД, если её нет |
| `mix db.migrate` | применяет новые миграции |
| `mix db.setup` | `db.create` + `db.migrate` |
| `mix db.drop` | удаляет БД (запрещено в prod) |
| `mix db.reset` | `db.drop` + `db.setup` |
| `mix test` | создаёт и мигрирует тестовую БД, запускает тесты |

Тесты с БД выполняются последовательно и очищают таблицы перед каждым тестом.

## Миграции

`priv/migrations/NNNN_name.sql`. Каждый файл применяется целиком в одной транзакции вместе с записью в `schema_migrations`. Пока нет развёрнутых баз, миграции правятся на месте (`mix db.reset`); после первого развёртывания применённую миграцию не редактируем — изменения новым файлом. Отката нет. Ограничения финансовых таблиц (DOMAIN, «Финансовые инварианты») не ослабляются без записи в DECISIONS.

## Код

```
lib/networth/
  db.ex              пул Postgrex, запросы, транзакции
  migrator.ex        применение SQL-миграций
  uuid.ex            UUID как строки; Postgrex-расширение для типа uuid
  money.ex           разбор/форматирование сумм, курс обмена
  currencies.ex      справочник валют
  params.ex          проверка внешних параметров
  scope.ex           %Scope{user_id, workspace_id, role}
  users.ex           регистрация, вход, пароли, токены
  rate_limit.ex      счётчики попыток в ETS
  workspaces.ex      workspaces, членство, приглашения, authorize/2
  accounts.ex        счета, системные счета, балансы
  ledger.ex          проведение операций, сторно, история
  reports.ex         отчёты (только чтение)
  budgets.ex         бюджеты: лимиты и отчёт исполнения
  categories.ex      категории
  tags.ex            теги
  web/router.ex      HTTP API
  web/json.ex        представление данных в ответах
```

Доменные функции принимают `%Scope{}` (его выдаёт только `Workspaces.authorize/2`) и map параметров со строковыми ключами и возвращают `{:ok, value}`, `:ok` или `{:error, reason}`. Роутер только аутентифицирует, вызывает домен и рендерит результат:

| Результат | HTTP |
|---|---|
| `{:ok, value}` / `:ok` | 200, 201 / 204 |
| `{:error, {:invalid, %{"field" => "message"}}}` | 422 |
| `{:error, :not_found}` (в т. ч. чужой workspace) | 404 |
| `{:error, :forbidden}` | 403 |
| `{:error, :idempotency_key_reused \| :id_taken \| :last_owner}` | 409 |
| нет или неверный токен | 401 |

## HTTP API

JSON. Все id — UUID-строки, суммы — десятичные строки. Кроме регистрации, входа и валют нужен `Authorization: Bearer <token>`.

| Метод и путь | Назначение |
|---|---|
| `POST /api/register` | `{email, name, password, timezone?}` → пользователь, личный workspace, токен |
| `POST /api/login`, `POST /api/logout` | вход / отзыв текущего токена; слишком много попыток — 429 с `retry-after` |
| `GET /api/me` | пользователь и его workspaces |
| `GET /api/currencies` | справочник валют |
| `GET/POST /api/workspaces` | список / создание `{name, timezone?}` |
| `GET/PATCH /api/workspaces/:wid` | просмотр / `{name?, timezone?}` (owner) |
| `GET /api/workspaces/:wid/members` | участники |
| `PATCH /api/workspaces/:wid/members/:user_id` | роль `{role}` (owner) |
| `DELETE /api/workspaces/:wid/members/:user_id` | удалить участника (owner) или выйти (свой id) |
| `GET/POST /api/workspaces/:wid/invitations`, `DELETE …/:id` | приглашения (owner) |
| `GET /api/invitations`, `POST /api/invitations/:id/accept` | мои приглашения / принять |
| `GET/POST /api/workspaces/:wid/accounts` | счета с балансами / `{name, type, currency, opening_balance?, opened_on?, idempotency_key?}`; `type`: cash, bank, card, deposit, savings, receivable, credit_card, loan, payable |
| `GET/PATCH /api/workspaces/:wid/accounts/:id` | счёт / `{name?, archived?}` |
| `GET /api/workspaces/:wid/accounts/:id/activity?from=&to=` | движение по счёту: остаток на начало, приход, расход, остаток на конец |
| `GET /api/workspaces/:wid/reports/income-expense?from=&to=` | доходы и расходы по валютам и категориям, итог |
| `GET /api/workspaces/:wid/reports/balances?on=` | балансы счетов на конец даты |
| `GET /api/workspaces/:wid/budgets` | лимиты с историей |
| `PUT /api/workspaces/:wid/budgets` | лимит `{category_id, currency, amount, month?}` с месяца `YYYY-MM`; `amount: "0"` снимает |
| `GET /api/workspaces/:wid/reports/budget?month=` | лимит, потрачено, остаток, процент по категориям |
| `GET /api/workspaces/:wid/reports/net-worth?on=` | капитал по валютам: активы, обязательства, разница (по умолчанию на сегодня) |
| `GET /api/workspaces/:wid/transactions` | история, новые сверху; `account_id, category_id, tag_id, type, from, to, limit, cursor` → `{transactions, next_cursor}` |
| `POST /api/workspaces/:wid/transactions` | провести операцию |
| `GET /api/workspaces/:wid/transactions/:id` | операция с проводками |
| `PATCH /api/workspaces/:wid/transactions/:id` | изменить описание `{description}`; остальное — только через сторно |
| `GET /api/workspaces/:wid/transactions/:id/changes` | журнал изменений описания |
| `POST /api/workspaces/:wid/transactions/:id/reverse` | сторно `{occurred_on?, description?}`; повтор возвращает то же сторно |
| `PUT /api/workspaces/:wid/transactions/:id/tags` | заменить теги `{tag_ids}` |
| `GET/POST /api/workspaces/:wid/categories`, `PATCH …/:id` | категории |
| `GET/POST /api/workspaces/:wid/tags`, `PATCH/DELETE …/:id` | теги |

Тела операций (`occurred_on` по умолчанию — сегодня в часовом поясе workspace; `lines` — split по категориям вместо `amount` + `category_id`):

```json
{"type": "expense",  "account_id": "…", "amount": "200000", "category_id": "…", "tag_ids": ["…"], "occurred_on": "2026-11-10", "description": "Продукты", "idempotency_key": "…", "id": "<UUIDv7, необязательно>"}
{"type": "expense",  "account_id": "…", "lines": [{"amount": "200000", "category_id": "…"}, {"amount": "100000", "category_id": "…"}]}
{"type": "income",   "account_id": "…", "amount": "15000000", "category_id": "…"}
{"type": "transfer", "from_account_id": "…", "to_account_id": "…", "amount": "1000000"}
{"type": "exchange", "from_account_id": "…", "from_amount": "100", "to_account_id": "…", "to_amount": "1270000", "fee": "1.50", "fee_category_id": "…"}
```
