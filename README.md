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

## Production

Сборка — `mix release`, Mix и исходники на сервере не нужны:

```sh
MIX_ENV=prod mix release
export DATABASE_URL=postgres://user:pass@host:5432/networth PORT=4000
_build/prod/rel/networth/bin/networth eval "Networth.Release.migrate()"   # применить миграции
_build/prod/rel/networth/bin/networth start                                # или daemon / stop
```

В prod `DATABASE_URL` обязательна, HTTP-сервер включён всегда. `GET /health` проверяет соединение с БД: 200 `{"status":"ok"}` или 503 (при недоступной БД ответ приходит через ~5 с — таймаут ожидания соединения в пуле). Релиз собирается под ту же ОС и архитектуру, где будет запущен.

## Миграции

`priv/migrations/NNNN_name.sql`. Каждый файл применяется целиком в одной транзакции вместе с записью в `schema_migrations`. Пока нет развёрнутых баз, миграции правятся на месте (`mix db.reset`); после первого развёртывания применённую миграцию не редактируем — изменения новым файлом. Отката нет. Ограничения финансовых таблиц (DOMAIN, «Финансовые инварианты») не ослабляются без записи в DECISIONS.

## Код

Модуль контекста (`ledger.ex`, `workspaces.ex`) — публичный API; когда он разрастается, части уходят в одноимённую папку, а модуль делегирует им (`defdelegate`). Тесты повторяют эту раскладку.

```
lib/networth/
  application.ex     супервизор: пул БД, счётчики попыток, обслуживание, HTTP
  db.ex              пул Postgrex, запросы, транзакции, хелперы WHERE
  db/
    migrator.ex      применение SQL-миграций
    uuid.ex          UUID как строки; Postgrex-расширение для типа uuid
    types.ex         типы Postgrex с этим расширением
  release.ex         миграции в собранном релизе
  money.ex           разбор/форматирование сумм, курс обмена
  currencies.ex      справочник валют
  params.ex          проверка внешних параметров
  scope.ex           %Scope{user_id, workspace_id, role}
  users.ex           регистрация, вход, пароли, токены
  rate_limit.ex      счётчики попыток в ETS
  maintenance.ex     ежечасно: просроченные токены, удаление назначенных workspace
  workspaces.ex      создание, authorize/2, настройки; API частей ниже
  workspaces/
    members.ex       участники и роли, «всегда есть owner»
    invitations.ex   приглашения
    deletion.ex      отложенное удаление и очистка
  accounts.ex        счета, системные счета, балансы
  ledger.ex          публичный API ledger
  ledger/
    posting.ex       проведение: параметры, проводки, запись, идемпотентность
    reversal.ex      сторно
    correction.ex    исправление
    adjustment.ex    сверка баланса
    editing.ex       описание и теги проведённой операции
    history.ex       чтение: get, list, курсор, снимок для журнала
  activity.ex        журнал активности workspace
  reports.ex         отчёты (только чтение)
  budgets.ex         бюджеты: лимиты и отчёт исполнения
  categories.ex      категории
  tags.ex            теги
  web/
    router.ex            вход API: публичные маршруты, маршруты пользователя, forward в workspace
    workspace_router.ex  всё внутри /api/workspaces/:wid; scope из conn.assigns
    auth.ex              plug-и: пользователь по токену (кроме публичных путей), членство → scope
    response.ex          отправка JSON, результаты и ошибки ядра → статусы HTTP
    serializer.ex        форма данных в ответах, включая ошибки валидации
    error_messages.ex    словарь: код ошибки валидации → английский текст
```

Доменные функции принимают `%Scope{}` (его выдаёт только `Workspaces.authorize/2`) и map параметров со строковыми ключами и возвращают `{:ok, value}`, `:ok` или `{:error, reason}`. Маршрут только вызывает домен и отправляет результат; токен и членство проверяют plug-и (`Web.Auth`), статусы задаёт `Web.Response`:

| Результат | HTTP |
|---|---|
| `{:ok, value}` / `:ok` | 200, 201 / 204 |
| `{:error, {:invalid, %{"field" => %{code: :too_long, max: 100}}}}` | 422 |
| `{:error, :not_found}` (в т. ч. чужой workspace) | 404 |
| `{:error, :forbidden}` | 403 |
| `{:error, :idempotency_key_reused \| :id_taken \| :last_owner \| :already_reversed}` | 409 |
| `{:error, {:rate_limited, seconds}}` | 429, `retry-after` |
| нет или неверный токен | 401 |

## HTTP API

### Формат ответов

- Успех — объект под именем ресурса: `{"account": {...}}`; список — `{"accounts": [...]}`; страница с курсором — `{"transactions": [...], "next_cursor": "..." | null}`; отчёт — `{"report": {...}}`; нет содержимого — 204.
- Ошибка — `{"error": "<код>"}`, где код — имя ошибки ядра (`not_found`, `forbidden`, `last_owner`, `rate_limited`, …). У ошибки валидации (422) добавляется `"errors"` по полям (ниже). 429 приходит с заголовком `retry-after`.
- Значения: id — UUID-строки; деньги — десятичные строки с валютой рядом (`"amount": "12.50", "currency": "USD"`); даты — `YYYY-MM-DD`; время — ISO 8601 в UTC.
- `/health` — исключение по договорённости health-проверок: `{"status": "ok"}` (200) или `{"status": "database_unavailable"}` (503).

Ошибка валидации — 422 со всеми неверными полями сразу; у каждого поля стабильный `code`, детали и английский `message`. Клиент показывает текст на своём языке по `code`:

```json
{"error": "invalid", "errors": {
  "amount": {"code": "too_many_decimals", "currency": "JPY", "decimals": 0, "message": "JPY allows at most 0 decimal places"},
  "occurred_on": {"code": "invalid_date", "message": "must be an ISO 8601 date"}
}}
```

Тексты по кодам — в `Networth.Web.ErrorMessages`.

JSON. Все id — UUID-строки, суммы — десятичные строки. Кроме регистрации, входа и валют нужен `Authorization: Bearer <token>`.

| Метод и путь | Назначение |
|---|---|
| `GET /health` | проверка соединения с БД, без авторизации |
| `POST /api/register` | `{email, name, password, timezone?}` → пользователь, личный workspace, токен |
| `POST /api/login`, `POST /api/logout` | вход / отзыв текущего токена; слишком много попыток — 429 `rate_limited` с `retry-after` |
| `GET /api/me` | пользователь и его workspaces |
| `GET /api/currencies` | справочник валют |
| `GET/POST /api/workspaces` | список / создание `{name, timezone?}` |
| `GET/PATCH /api/workspaces/:wid` | просмотр / `{name?, timezone?}` (owner) |
| `DELETE /api/workspaces/:wid` | назначить удаление через 7 дней `{confirm: <имя workspace>}` (owner); 202 |
| `POST /api/workspaces/:wid/restore` | отменить назначенное удаление (owner) |
| `GET /api/workspaces/:wid/members` | участники |
| `GET /api/workspaces/:wid/activity` | журнал активности, новые сверху; `subject_id, actor_id, limit, cursor` → `{events, next_cursor}` |
| `PATCH /api/workspaces/:wid/members/:user_id` | роль `{role}` (owner) |
| `DELETE /api/workspaces/:wid/members/:user_id` | удалить участника (owner) или выйти (свой id) |
| `GET/POST /api/workspaces/:wid/invitations`, `DELETE …/:id` | приглашения (owner) |
| `GET /api/invitations`, `POST /api/invitations/:id/accept` | мои приглашения / принять |
| `GET/POST /api/workspaces/:wid/accounts` | счета с балансами / `{name, type, currency, opening_balance?, opened_on?, idempotency_key?}`; `type`: cash, bank, card, deposit, savings, receivable, credit_card, loan, payable |
| `GET/PATCH /api/workspaces/:wid/accounts/:id` | счёт / `{name?, archived?}` |
| `POST /api/workspaces/:wid/accounts/:id/adjust` | сверка `{balance, occurred_on?, description?}`: проводит разницу; `transaction: null`, если совпадает |
| `GET /api/workspaces/:wid/accounts/:id/activity?from=&to=` | движение по счёту: остаток на начало, приход, расход, остаток на конец |
| `GET /api/workspaces/:wid/reports/income-expense?from=&to=` | доходы и расходы по валютам и категориям, итог |
| `GET /api/workspaces/:wid/reports/balances?on=` | балансы счетов на конец даты |
| `GET /api/workspaces/:wid/budgets` | лимиты с историей |
| `PUT /api/workspaces/:wid/budgets` | лимит `{category_id, currency, amount, month?}` с месяца `YYYY-MM`; `amount: "0"` снимает |
| `GET /api/workspaces/:wid/reports/budget?month=` | лимит, потрачено, остаток, процент по категориям |
| `GET /api/workspaces/:wid/reports/net-worth?on=` | капитал по валютам: активы, обязательства, разница (по умолчанию на сегодня) |
| `GET /api/workspaces/:wid/transactions` | история, новые сверху, без отменённых пар; `account_id, category_id, tag_id, type, from, to, include_reversed, limit, cursor` → `{transactions, next_cursor}` |
| `POST /api/workspaces/:wid/transactions` | провести операцию |
| `GET /api/workspaces/:wid/transactions/:id` | операция с проводками |
| `PATCH /api/workspaces/:wid/transactions/:id` | изменить описание `{description}`; остальное — только через сторно |
| `POST /api/workspaces/:wid/transactions/:id/reverse` | сторно `{occurred_on?, description?}`; повтор возвращает то же сторно |
| `POST /api/workspaces/:wid/transactions/:id/correct` | исправить: сторно + новая версия (тело как у проведения), `replaces_id` на исходную |
| `DELETE /api/workspaces/:wid/transactions/:id` | удалить (сторно); 204 |
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
