# Demo data for development: `mix db.seed`.
#
# Two users (demo@networth.local and partner@networth.local, password
# "demo-password"), a personal workspace with three months of operations,
# debts, a correction, a balance adjustment and budgets, and a family
# workspace shared by both. Everything goes through the core, like a real
# client. Running it again changes nothing.

alias Networth.{Accounts, Budgets, Categories, Ledger, Tags, Users, Workspaces}

password = "demo-password"
ok! = fn {:ok, value} -> value end
iso = &Date.to_iso8601/1

seed = fn ->
  %{user: demo, workspace: personal} =
    ok!.(
      Users.register(%{
        "email" => "demo@networth.local",
        "name" => "Demo",
        "password" => password,
        "timezone" => "Asia/Tashkent"
      })
    )

  %{user: partner} =
    ok!.(
      Users.register(%{
        "email" => "partner@networth.local",
        "name" => "Partner",
        "password" => password,
        "timezone" => "Asia/Tashkent"
      })
    )

  s = ok!.(Workspaces.authorize(demo.id, personal.id))
  today = Workspaces.today(s)
  start = today |> Date.beginning_of_month() |> Date.shift(month: -2)
  category = fn scope, name -> Enum.find(Categories.list(scope), &(&1.name == name)).id end

  account = fn scope, attrs ->
    ok!.(Accounts.create(scope, Map.put_new(attrs, "opened_on", iso.(start))))
  end

  cash =
    account.(s, %{
      "name" => "Наличные",
      "type" => "cash",
      "currency" => "UZS",
      "opening_balance" => "2000000"
    })

  card =
    account.(s, %{
      "name" => "Карта",
      "type" => "card",
      "currency" => "UZS",
      "opening_balance" => "15000000"
    })

  usd =
    account.(s, %{
      "name" => "Наличные USD",
      "type" => "cash",
      "currency" => "USD",
      "opening_balance" => "500"
    })

  credit =
    account.(s, %{
      "name" => "Кредитка",
      "type" => "credit_card",
      "currency" => "UZS",
      "opening_balance" => "1200000"
    })

  sasha = account.(s, %{"name" => "Саша", "type" => "receivable", "currency" => "UZS"})

  food = category.(s, "Food")
  cafe = ok!.(Categories.create(s, %{"name" => "Cafe", "parent_id" => food})).id
  household = ok!.(Categories.create(s, %{"name" => "Household", "kind" => "expense"})).id
  friends = ok!.(Tags.create(s, %{"name" => "Друзья", "color" => "#f59e0b"})).id

  # Operations dated after today are skipped, so the current month is partial.
  post = fn scope, date, attrs ->
    if Date.compare(date, today) != :gt do
      ok!.(Ledger.post(scope, Map.put(attrs, "occurred_on", iso.(date))))
    end
  end

  for month <- 0..2 do
    day = &Date.add(Date.shift(start, month: month), &1 - 1)

    post.(s, day.(1), %{
      "type" => "expense",
      "account_id" => card.id,
      "amount" => "3000000",
      "category_id" => category.(s, "Housing"),
      "description" => "Аренда"
    })

    post.(s, day.(5), %{
      "type" => "income",
      "account_id" => card.id,
      "amount" => "15000000",
      "category_id" => category.(s, "Salary"),
      "description" => "Зарплата"
    })

    for d <- [3, 10, 17, 24] do
      post.(s, day.(d), %{
        "type" => "expense",
        "account_id" => cash.id,
        "amount" => "350000",
        "category_id" => food,
        "description" => "Продукты"
      })
    end

    for d <- [7, 21] do
      post.(s, day.(d), %{
        "type" => "expense",
        "account_id" => card.id,
        "amount" => "120000",
        "category_id" => category.(s, "Transport"),
        "description" => "Такси"
      })
    end

    post.(s, day.(12), %{
      "type" => "expense",
      "account_id" => card.id,
      "description" => "Чек из супермаркета",
      "lines" => [
        %{"amount" => "400000", "category_id" => food},
        %{"amount" => "150000", "category_id" => household}
      ]
    })

    post.(s, day.(14), %{
      "type" => "expense",
      "account_id" => cash.id,
      "amount" => "180000",
      "category_id" => cafe,
      "tag_ids" => [friends],
      "description" => "Ужин с друзьями"
    })

    post.(s, day.(18), %{
      "type" => "expense",
      "account_id" => credit.id,
      "amount" => "600000",
      "category_id" => category.(s, "Shopping"),
      "description" => "Кроссовки"
    })

    post.(s, day.(25), %{
      "type" => "transfer",
      "from_account_id" => card.id,
      "to_account_id" => credit.id,
      "amount" => "600000",
      "description" => "Погашение кредитки"
    })
  end

  post.(s, Date.add(start, 14), %{
    "type" => "exchange",
    "from_account_id" => usd.id,
    "from_amount" => "100",
    "to_account_id" => card.id,
    "to_amount" => "1270000",
    "fee" => "1",
    "fee_category_id" => category.(s, "Shopping"),
    "description" => "Обмен в банке"
  })

  post.(s, Date.add(start, 19), %{
    "type" => "transfer",
    "from_account_id" => cash.id,
    "to_account_id" => sasha.id,
    "amount" => "500000",
    "description" => "Дал в долг"
  })

  post.(s, Date.add(start, 40), %{
    "type" => "transfer",
    "from_account_id" => sasha.id,
    "to_account_id" => cash.id,
    "amount" => "200000",
    "description" => "Вернул часть"
  })

  typo =
    post.(s, Date.add(start, 8), %{
      "type" => "expense",
      "account_id" => card.id,
      "amount" => "1000000",
      "category_id" => category.(s, "Entertainment"),
      "description" => "Кино"
    })

  ok!.(
    Ledger.correct(s, typo.id, %{
      "type" => "expense",
      "account_id" => card.id,
      "amount" => "100000",
      "category_id" => category.(s, "Entertainment")
    })
  )

  # Forgot to record a few cash expenses: reconcile with the real balance.
  {:ok, %{balance: cash_balance}} = Accounts.get(s, cash.id)

  ok!.(
    Ledger.adjust_balance(s, cash.id, %{
      "balance" => Networth.Money.format(cash_balance - 3_700_000, "UZS")
    })
  )

  for {name, amount} <- [{"Food", "2000000"}, {"Transport", "500000"}] do
    ok!.(
      Budgets.set(s, %{
        "category_id" => category.(s, name),
        "currency" => "UZS",
        "amount" => amount,
        "month" => Calendar.strftime(start, "%Y-%m")
      })
    )
  end

  family = ok!.(Workspaces.create(demo.id, %{"name" => "Семья", "timezone" => "Asia/Tashkent"}))
  f = ok!.(Workspaces.authorize(demo.id, family.id))
  invitation = ok!.(Workspaces.invite(f, %{"email" => partner.email}))
  ok!.(Workspaces.accept_invitation(partner, invitation.id))
  pf = ok!.(Workspaces.authorize(partner.id, family.id))

  shared =
    account.(f, %{
      "name" => "Общая карта",
      "type" => "card",
      "currency" => "UZS",
      "opening_balance" => "3000000"
    })

  post.(pf, Date.add(today, -1), %{
    "type" => "expense",
    "account_id" => shared.id,
    "amount" => "450000",
    "category_id" => category.(pf, "Food"),
    "description" => "Продукты на неделю"
  })

  IO.puts("Seeded: demo@networth.local and partner@networth.local, password #{password}")
end

case Users.authenticate("demo@networth.local", password) do
  {:ok, _} -> IO.puts("Demo data already present, nothing to do")
  {:error, :invalid_credentials} -> seed.()
end
