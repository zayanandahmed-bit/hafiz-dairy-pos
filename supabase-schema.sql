-- Hafiz Dairy POS — Supabase database schema.
--
-- One-time setup (in your own Supabase account):
-- 1. Go to https://supabase.com, sign up free, create a new project
--    (pick any name/region/password — you won't need the DB password again).
-- 2. In the left sidebar, open "SQL Editor" -> "New query".
-- 3. Paste this ENTIRE file in and click "Run".
-- 4. In the left sidebar, open "Project Settings" -> "API".
--    Copy the "Project URL" and the "anon public" key.
-- 5. Paste both into the app's Settings -> Cloud Sync (Supabase) panel.
--
-- Design: every table is locked down with Row Level Security (RLS) and NO
-- direct table access is granted to anyone. The only way in or out is
-- through the SECURITY DEFINER functions below, which run with elevated
-- privileges but only do exactly what they're written to do. This means
-- even someone who gets your anon key can only call these functions — they
-- can't run arbitrary queries against your tables.
--
-- Every add/edit/delete in the app saves to the database instantly:
-- sync_append_sale/sync_append_refund insert one record at a time (so sales
-- history never has to be resent in full), while sync_replace_* functions
-- wipe-and-rewrite just their own table (items, categories, suppliers,
-- purchases, cashiers, held sales, shifts, settings) whenever that specific
-- thing changes. sync_push/sync_pull remain as a full-dataset replace/read,
-- used only for restoring a backup file.

-- ============== TABLES ==============

create table if not exists items (
  id text primary key,
  name text not null,
  barcode text default '',
  category text default '',
  price numeric default 0,
  stock numeric default 0,
  unit text default '',
  low_stock numeric default 0
);

create table if not exists categories (
  name text primary key
);

create table if not exists suppliers (
  id text primary key,
  name text not null,
  contact text default '',
  address text default ''
);

create table if not exists cashiers (
  id text primary key,
  name text not null,
  pin text default ''
);

create table if not exists purchases (
  id text primary key,
  date date,
  supplier_id text,
  supplier_name text,
  item_id text,
  item_name text,
  qty numeric,
  cost numeric,
  total numeric,
  notes text default '',
  proof_data_url text,
  proof_name text
);

create table if not exists sales (
  id text primary key,
  receipt_no integer,
  date timestamptz,
  customer text,
  cashier text,
  payment text,
  cash numeric,
  subtotal numeric,
  discount_pct numeric,
  discount_amt numeric,
  tax_pct numeric,
  tax_amt numeric,
  grand numeric
);

create table if not exists sale_lines (
  sale_id text,
  item_id text,
  item_name text,
  barcode text,
  price numeric,
  qty numeric,
  unit text,
  subtotal numeric
);

create table if not exists refunds (
  id text primary key,
  sale_id text,
  receipt_no integer,
  date timestamptz,
  total numeric,
  reason text,
  cashier text
);

create table if not exists refund_lines (
  refund_id text,
  item_id text,
  item_name text,
  qty numeric,
  price numeric,
  refund_amount numeric
);

create table if not exists held_sales (
  id text primary key,
  date timestamptz,
  customer text,
  discount numeric,
  tax numeric,
  cashier text
);

create table if not exists held_sales_cart (
  held_id text,
  item_id text,
  qty numeric
);

create table if not exists shifts (
  id text primary key,
  cashier_name text,
  start timestamptz,
  "end" timestamptz,
  opening_cash numeric,
  cash_sales numeric,
  card_sales numeric,
  wallet_sales numeric,
  cash_refunds numeric,
  txn_count integer,
  expected_cash numeric,
  actual_cash numeric,
  difference numeric,
  notes text
);

create table if not exists active_shift (
  id text primary key,
  cashier_id text,
  cashier_name text,
  start timestamptz,
  opening_cash numeric
);

create table if not exists settings (
  key text primary key,
  value text
);

create table if not exists meta (
  key text primary key,
  value text
);

-- Running totals, kept up to date by triggers below (not recomputed on
-- read). "All Time" stats/top-items come from these instead of scanning the
-- full sales/sale_lines tables — the live scan approach that used to time
-- out once sales history got into the tens of thousands. Any bounded range
-- (Today/This Week/This Month/Custom) still scans live, since an indexed
-- date filter keeps that fast regardless of total table size.

create table if not exists item_sales_totals (
  item_name text primary key,
  qty numeric default 0,
  revenue numeric default 0
);

create table if not exists sales_overall_totals (
  key text primary key,
  count integer default 0,
  revenue numeric default 0
);
insert into sales_overall_totals (key, count, revenue) values ('all', 0, 0)
on conflict (key) do nothing;

-- ============== LOCK EVERYTHING DOWN ==============
-- RLS enabled, no policies granted = nobody can touch these tables directly,
-- not even with the anon key. Only the SECURITY DEFINER functions below can.

alter table items enable row level security;
alter table categories enable row level security;
alter table suppliers enable row level security;
alter table cashiers enable row level security;
alter table purchases enable row level security;
alter table sales enable row level security;
alter table sale_lines enable row level security;
alter table refunds enable row level security;
alter table refund_lines enable row level security;
alter table held_sales enable row level security;
alter table held_sales_cart enable row level security;
alter table shifts enable row level security;
alter table active_shift enable row level security;
alter table settings enable row level security;
alter table meta enable row level security;
alter table item_sales_totals enable row level security;
alter table sales_overall_totals enable row level security;

-- ============== triggers: keep running totals in sync ==============
-- Fire on every insert/update/delete to sales/sale_lines, regardless of
-- which function touched them (single append, batch append, full replace,
-- or clear) — so the totals never need a separate maintenance step.

create or replace function trg_sale_lines_totals()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'INSERT' then
    insert into item_sales_totals (item_name, qty, revenue)
    values (NEW.item_name, NEW.qty, NEW.subtotal)
    on conflict (item_name) do update set
      qty = item_sales_totals.qty + NEW.qty,
      revenue = item_sales_totals.revenue + NEW.subtotal;
    return NEW;
  elsif TG_OP = 'DELETE' then
    update item_sales_totals set qty = qty - OLD.qty, revenue = revenue - OLD.subtotal
    where item_name = OLD.item_name;
    return OLD;
  end if;
  return null;
end;
$$;

drop trigger if exists sale_lines_totals_trigger on sale_lines;
create trigger sale_lines_totals_trigger
after insert or delete on sale_lines
for each row execute function trg_sale_lines_totals();

create or replace function trg_sales_totals()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'INSERT' then
    update sales_overall_totals set count = count + 1, revenue = revenue + NEW.grand where key = 'all';
    return NEW;
  elsif TG_OP = 'DELETE' then
    update sales_overall_totals set count = count - 1, revenue = revenue - OLD.grand where key = 'all';
    return OLD;
  elsif TG_OP = 'UPDATE' then
    update sales_overall_totals set revenue = revenue - OLD.grand + NEW.grand where key = 'all';
    return NEW;
  end if;
  return null;
end;
$$;

drop trigger if exists sales_totals_trigger on sales;
create trigger sales_totals_trigger
after insert or update or delete on sales
for each row execute function trg_sales_totals();

-- One-time (and safely re-runnable) backfill, so totals stay correct even
-- for rows that existed before these triggers did. Only touches the summary
-- tables, so it's cheap regardless of when it runs.
insert into item_sales_totals (item_name, qty, revenue)
select item_name, sum(qty), sum(subtotal) from sale_lines group by item_name
on conflict (item_name) do update set qty = excluded.qty, revenue = excluded.revenue;

update sales_overall_totals
set count = (select count(*) from sales), revenue = (select coalesce(sum(grand), 0) from sales)
where key = 'all';

-- ============== sync_push: atomic full-replace write ==============

create or replace function sync_push(payload jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if payload ? 'items' then
    delete from items where true;
    insert into items (id, name, barcode, category, price, stock, unit, low_stock)
    select x->>'id', x->>'name', coalesce(x->>'barcode',''), coalesce(x->>'category',''),
           coalesce((x->>'price')::numeric,0), coalesce((x->>'stock')::numeric,0),
           coalesce(x->>'unit',''), coalesce((x->>'lowStock')::numeric,0)
    from jsonb_array_elements(payload->'items') x;
  end if;

  if payload ? 'categories' then
    delete from categories where true;
    insert into categories (name)
    select jsonb_array_elements_text(payload->'categories');
  end if;

  if payload ? 'suppliers' then
    delete from suppliers where true;
    insert into suppliers (id, name, contact, address)
    select x->>'id', x->>'name', coalesce(x->>'contact',''), coalesce(x->>'address','')
    from jsonb_array_elements(payload->'suppliers') x;
  end if;

  if payload ? 'cashiers' then
    delete from cashiers where true;
    insert into cashiers (id, name, pin)
    select x->>'id', x->>'name', coalesce(x->>'pin','')
    from jsonb_array_elements(payload->'cashiers') x;
  end if;

  if payload ? 'purchases' then
    delete from purchases where true;
    insert into purchases (id, date, supplier_id, supplier_name, item_id, item_name, qty, cost, total, notes, proof_data_url, proof_name)
    select x->>'id',
           nullif(x->>'date','')::date,
           x->>'supplierId', x->>'supplierName', x->>'itemId', x->>'itemName',
           (x->>'qty')::numeric, (x->>'cost')::numeric, (x->>'total')::numeric, coalesce(x->>'notes',''),
           x->>'proof', x->>'proofName'
    from jsonb_array_elements(payload->'purchases') x;
  end if;

  if payload ? 'sales' then
    -- TRUNCATE (not DELETE) so this doesn't fire the per-row totals triggers
    -- thousands of times over on a full replace — reset the summary tables
    -- directly instead, then let the inserts below rebuild them correctly.
    truncate sale_lines;
    truncate sales;
    truncate item_sales_totals;
    update sales_overall_totals set count = 0, revenue = 0 where key = 'all';

    insert into sales (id, receipt_no, date, customer, cashier, payment, cash, subtotal, discount_pct, discount_amt, tax_pct, tax_amt, grand)
    select x->>'id', (x->>'receiptNo')::integer, (x->>'date')::timestamptz, x->>'customer', x->>'cashier', x->>'payment',
           (x->>'cash')::numeric, (x->>'subtotal')::numeric, (x->>'discountPct')::numeric, (x->>'discountAmt')::numeric,
           (x->>'taxPct')::numeric, (x->>'taxAmt')::numeric, (x->>'grand')::numeric
    from jsonb_array_elements(payload->'sales') x;

    insert into sale_lines (sale_id, item_id, item_name, barcode, price, qty, unit, subtotal)
    select s->>'id', l->>'itemId', l->>'name', coalesce(l->>'barcode',''), (l->>'price')::numeric,
           (l->>'qty')::numeric, coalesce(l->>'unit',''), (l->>'subtotal')::numeric
    from jsonb_array_elements(payload->'sales') s,
         jsonb_array_elements(coalesce(s->'lines','[]'::jsonb)) l;
  end if;

  if payload ? 'refunds' then
    delete from refund_lines where true;
    delete from refunds where true;
    insert into refunds (id, sale_id, receipt_no, date, total, reason, cashier)
    select x->>'id', x->>'saleId', (x->>'receiptNo')::integer, (x->>'date')::timestamptz,
           (x->>'total')::numeric, coalesce(x->>'reason',''), x->>'cashier'
    from jsonb_array_elements(payload->'refunds') x;

    insert into refund_lines (refund_id, item_id, item_name, qty, price, refund_amount)
    select r->>'id', l->>'itemId', l->>'name', (l->>'qty')::numeric, (l->>'price')::numeric, (l->>'refundAmount')::numeric
    from jsonb_array_elements(payload->'refunds') r,
         jsonb_array_elements(coalesce(r->'lines','[]'::jsonb)) l;
  end if;

  if payload ? 'heldSales' then
    delete from held_sales_cart where true;
    delete from held_sales where true;
    insert into held_sales (id, date, customer, discount, tax, cashier)
    select x->>'id', (x->>'date')::timestamptz, x->>'customer', (x->>'discount')::numeric, (x->>'tax')::numeric, x->>'cashier'
    from jsonb_array_elements(payload->'heldSales') x;

    insert into held_sales_cart (held_id, item_id, qty)
    select h->>'id', c->>'itemId', (c->>'qty')::numeric
    from jsonb_array_elements(payload->'heldSales') h,
         jsonb_array_elements(coalesce(h->'cart','[]'::jsonb)) c;
  end if;

  if payload ? 'shifts' then
    delete from shifts where true;
    insert into shifts (id, cashier_name, start, "end", opening_cash, cash_sales, card_sales, wallet_sales, cash_refunds, txn_count, expected_cash, actual_cash, difference, notes)
    select x->>'id', x->>'cashierName', (x->>'start')::timestamptz, (x->>'end')::timestamptz,
           (x->>'openingCash')::numeric, (x->>'cashSales')::numeric, (x->>'cardSales')::numeric, (x->>'walletSales')::numeric,
           (x->>'cashRefunds')::numeric, (x->>'txnCount')::integer, (x->>'expectedCash')::numeric,
           (x->>'actualCash')::numeric, (x->>'difference')::numeric, coalesce(x->>'notes','')
    from jsonb_array_elements(payload->'shifts') x;
  end if;

  if payload ? 'activeShift' then
    delete from active_shift where true;
    if payload->'activeShift' is not null and payload->'activeShift' != 'null'::jsonb then
      insert into active_shift (id, cashier_id, cashier_name, start, opening_cash)
      values (
        payload->'activeShift'->>'id',
        payload->'activeShift'->>'cashierId',
        payload->'activeShift'->>'cashierName',
        (payload->'activeShift'->>'start')::timestamptz,
        (payload->'activeShift'->>'openingCash')::numeric
      );
    end if;
  end if;

  if payload ? 'settings' then
    delete from settings where true;
    insert into settings (key, value)
    select k, v
    from jsonb_each_text(payload->'settings') as t(k, v);
  end if;

  if payload ? 'receiptCounter' then
    insert into meta (key, value) values ('receiptCounter', (payload->>'receiptCounter'))
    on conflict (key) do update set value = excluded.value;
  end if;
end;
$$;

-- ============== sync_pull: read everything EXCEPT sales/refunds ==============
-- Sales and refunds are deliberately left out here — that history can grow
-- without bound, and building/sending all of it on every app load is what
-- broke this at high volume. Sales/refunds are fetched separately, scoped to
-- whatever date range the user has selected, by sync_pull_sales_range below.

create or replace function sync_pull()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
begin
  select jsonb_build_object(
    'items', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'barcode', barcode, 'category', category,
      'price', price, 'stock', stock, 'unit', unit, 'lowStock', low_stock
    )) from items), '[]'::jsonb),

    'categories', coalesce((select jsonb_agg(name) from categories), '[]'::jsonb),

    'suppliers', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'contact', contact, 'address', address
    )) from suppliers), '[]'::jsonb),

    'cashiers', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'pin', pin
    )) from cashiers), '[]'::jsonb),

    'purchases', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'date', date, 'supplierId', supplier_id, 'supplierName', supplier_name,
      'itemId', item_id, 'itemName', item_name, 'qty', qty, 'cost', cost, 'total', total,
      'notes', notes, 'proof', proof_data_url, 'proofName', proof_name
    )) from purchases), '[]'::jsonb),

    'heldSales', coalesce((select jsonb_agg(
      jsonb_build_object(
        'id', h.id, 'date', h.date, 'customer', h.customer, 'discount', h.discount,
        'tax', h.tax, 'cashier', h.cashier,
        'cart', coalesce((select jsonb_agg(jsonb_build_object(
          'itemId', hc.item_id, 'qty', hc.qty
        )) from held_sales_cart hc where hc.held_id = h.id), '[]'::jsonb)
      )
    ) from held_sales h), '[]'::jsonb),

    'shifts', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'cashierName', cashier_name, 'start', start, 'end', "end",
      'openingCash', opening_cash, 'cashSales', cash_sales, 'cardSales', card_sales,
      'walletSales', wallet_sales, 'cashRefunds', cash_refunds, 'txnCount', txn_count,
      'expectedCash', expected_cash, 'actualCash', actual_cash, 'difference', difference, 'notes', notes
    )) from shifts), '[]'::jsonb),

    'activeShift', (select jsonb_build_object(
      'id', id, 'cashierId', cashier_id, 'cashierName', cashier_name, 'start', start, 'openingCash', opening_cash
    ) from active_shift limit 1),

    'settings', coalesce((select jsonb_object_agg(key, value) from settings), '{}'::jsonb),

    'receiptCounter', (select (value)::integer from meta where key = 'receiptCounter')
  ) into result;
  return result;
end;
$$;

-- ============== indexes for range-scoped sales/refunds lookups ==============

create index if not exists idx_sales_date on sales(date);
create index if not exists idx_refunds_date on refunds(date);
create index if not exists idx_sale_lines_sale_id on sale_lines(sale_id);
create index if not exists idx_refund_lines_refund_id on refund_lines(refund_id);

-- ============== sync_pull_sales_range: sales/refunds for one date range ==============
-- Called whenever the user picks Today/This Week/This Month/Custom Range (or
-- All Time) in the Dashboard or Sales History — never on app load. Returns:
--   - sales/refunds: the actual rows for that range (capped at row_limit,
--     most recent first, so even an unbounded "All Time" row list responds fast)
--   - totalCount/totalRevenue/topItems: exact, regardless of the row cap —
--     for a BOUNDED range these come from a live indexed scan (fast no
--     matter how much total history exists, since the date filter narrows
--     it); for true "All Time" (both bounds null) they come from the
--     running-totals tables instead, since aggregating the entire table live
--     is exactly what timed out once sales history got into the tens of
--     thousands.
-- Pass null for range_start/range_end for an unbounded (All Time) range.

create or replace function sync_pull_sales_range(range_start timestamptz, range_end timestamptz, row_limit integer default 500)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
  is_all_time boolean := (range_start is null and range_end is null);
  v_total_count integer;
  v_total_revenue numeric;
  v_top_items jsonb;
begin
  if is_all_time then
    select count, revenue into v_total_count, v_total_revenue from sales_overall_totals where key = 'all';
    select coalesce(jsonb_agg(jsonb_build_object('name', item_name, 'qty', qty, 'revenue', revenue) order by qty desc), '[]'::jsonb)
    into v_top_items
    from (select * from item_sales_totals order by qty desc limit 20) t;
  else
    select count(*) into v_total_count from sales
    where (range_start is null or date >= range_start) and (range_end is null or date <= range_end);

    select coalesce(sum(grand), 0) into v_total_revenue from sales
    where (range_start is null or date >= range_start) and (range_end is null or date <= range_end);

    select coalesce(jsonb_agg(t order by (t->>'qty')::numeric desc), '[]'::jsonb) into v_top_items
    from (
      select jsonb_build_object('name', sl.item_name, 'qty', sum(sl.qty), 'revenue', sum(sl.subtotal)) as t
      from sale_lines sl
      join sales s on s.id = sl.sale_id
      where (range_start is null or s.date >= range_start) and (range_end is null or s.date <= range_end)
      group by sl.item_name
      limit 20
    ) t;
  end if;

  select jsonb_build_object(
    'sales', coalesce((
      select jsonb_agg(x order by x->>'date' desc) from (
        select jsonb_build_object(
          'id', s.id, 'receiptNo', s.receipt_no, 'date', s.date, 'customer', s.customer,
          'cashier', s.cashier, 'payment', s.payment, 'cash', s.cash, 'subtotal', s.subtotal,
          'discountPct', s.discount_pct, 'discountAmt', s.discount_amt, 'taxPct', s.tax_pct,
          'taxAmt', s.tax_amt, 'grand', s.grand,
          'lines', coalesce(sl.lines, '[]'::jsonb)
        ) as x
        from sales s
        left join (
          select sale_id, jsonb_agg(jsonb_build_object(
            'itemId', item_id, 'name', item_name, 'barcode', barcode,
            'price', price, 'qty', qty, 'unit', unit, 'subtotal', subtotal
          )) as lines
          from sale_lines group by sale_id
        ) sl on sl.sale_id = s.id
        where (range_start is null or s.date >= range_start)
          and (range_end is null or s.date <= range_end)
        order by s.date desc
        limit row_limit
      ) x
    ), '[]'::jsonb),

    'refunds', coalesce((
      select jsonb_agg(x order by x->>'date' desc) from (
        select jsonb_build_object(
          'id', r.id, 'saleId', r.sale_id, 'receiptNo', r.receipt_no, 'date', r.date,
          'total', r.total, 'reason', r.reason, 'cashier', r.cashier,
          'lines', coalesce(rl.lines, '[]'::jsonb)
        ) as x
        from refunds r
        left join (
          select refund_id, jsonb_agg(jsonb_build_object(
            'itemId', item_id, 'name', item_name, 'qty', qty,
            'price', price, 'refundAmount', refund_amount
          )) as lines
          from refund_lines group by refund_id
        ) rl on rl.refund_id = r.id
        where (range_start is null or r.date >= range_start)
          and (range_end is null or r.date <= range_end)
        order by r.date desc
        limit row_limit
      ) x
    ), '[]'::jsonb),

    'totalCount', v_total_count,
    'totalRevenue', v_total_revenue,
    'topItems', v_top_items
  ) into result;
  return result;
end;
$$;

-- ============== sync_append_sale: instant single-sale insert ==============
-- Used right after checkout, on every device, so a sale reaches the database
-- immediately without resending the entire sales history each time. Safe to
-- retry (e.g. after a dropped connection) since it upserts on the sale's id.

create or replace function sync_append_sale(sale jsonb, receipt_counter integer default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into sales (id, receipt_no, date, customer, cashier, payment, cash, subtotal, discount_pct, discount_amt, tax_pct, tax_amt, grand)
  values (
    sale->>'id', (sale->>'receiptNo')::integer, (sale->>'date')::timestamptz, sale->>'customer', sale->>'cashier', sale->>'payment',
    (sale->>'cash')::numeric, (sale->>'subtotal')::numeric, (sale->>'discountPct')::numeric, (sale->>'discountAmt')::numeric,
    (sale->>'taxPct')::numeric, (sale->>'taxAmt')::numeric, (sale->>'grand')::numeric
  )
  on conflict (id) do update set
    receipt_no = excluded.receipt_no, date = excluded.date, customer = excluded.customer,
    cashier = excluded.cashier, payment = excluded.payment, cash = excluded.cash,
    subtotal = excluded.subtotal, discount_pct = excluded.discount_pct, discount_amt = excluded.discount_amt,
    tax_pct = excluded.tax_pct, tax_amt = excluded.tax_amt, grand = excluded.grand;

  delete from sale_lines where sale_id = sale->>'id';
  insert into sale_lines (sale_id, item_id, item_name, barcode, price, qty, unit, subtotal)
  select sale->>'id', l->>'itemId', l->>'name', coalesce(l->>'barcode',''), (l->>'price')::numeric,
         (l->>'qty')::numeric, coalesce(l->>'unit',''), (l->>'subtotal')::numeric
  from jsonb_array_elements(coalesce(sale->'lines', '[]'::jsonb)) l;

  if receipt_counter is not null then
    insert into meta (key, value) values ('receiptCounter', receipt_counter::text)
    on conflict (key) do update set value = excluded.value;
  end if;
end;
$$;

-- ============== sync_append_sales_batch: bulk append, no wipe ==============
-- Set-based insert for many sales at once (e.g. bulk-loading historical data)
-- without ever deleting the existing table first, unlike sync_push. Callers
-- should chunk large loads (a few thousand sales per call) to stay under
-- Supabase's statement timeout — this function itself has no size limit,
-- the timeout is on how much work fits in one call.

create or replace function sync_append_sales_batch(sales jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into sales (id, receipt_no, date, customer, cashier, payment, cash, subtotal, discount_pct, discount_amt, tax_pct, tax_amt, grand)
  select x->>'id', (x->>'receiptNo')::integer, (x->>'date')::timestamptz, x->>'customer', x->>'cashier', x->>'payment',
         (x->>'cash')::numeric, (x->>'subtotal')::numeric, (x->>'discountPct')::numeric, (x->>'discountAmt')::numeric,
         (x->>'taxPct')::numeric, (x->>'taxAmt')::numeric, (x->>'grand')::numeric
  from jsonb_array_elements(sales) x
  on conflict (id) do nothing;

  insert into sale_lines (sale_id, item_id, item_name, barcode, price, qty, unit, subtotal)
  select s->>'id', l->>'itemId', l->>'name', coalesce(l->>'barcode',''), (l->>'price')::numeric,
         (l->>'qty')::numeric, coalesce(l->>'unit',''), (l->>'subtotal')::numeric
  from jsonb_array_elements(sales) s,
       jsonb_array_elements(coalesce(s->'lines','[]'::jsonb)) l;
end;
$$;

-- ============== sync_append_refund: instant single-refund insert ==============

create or replace function sync_append_refund(refund jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into refunds (id, sale_id, receipt_no, date, total, reason, cashier)
  values (
    refund->>'id', refund->>'saleId', (refund->>'receiptNo')::integer, (refund->>'date')::timestamptz,
    (refund->>'total')::numeric, coalesce(refund->>'reason',''), refund->>'cashier'
  )
  on conflict (id) do update set
    sale_id = excluded.sale_id, receipt_no = excluded.receipt_no, date = excluded.date,
    total = excluded.total, reason = excluded.reason, cashier = excluded.cashier;

  delete from refund_lines where refund_id = refund->>'id';
  insert into refund_lines (refund_id, item_id, item_name, qty, price, refund_amount)
  select refund->>'id', l->>'itemId', l->>'name', (l->>'qty')::numeric, (l->>'price')::numeric, (l->>'refundAmount')::numeric
  from jsonb_array_elements(coalesce(refund->'lines', '[]'::jsonb)) l;
end;
$$;

-- ============== sync_clear_sales: wipes sales/sale_lines only ==============
-- Used by "Clear all sales history" — a deliberate one-off admin action,
-- not something that happens per checkout.

create or replace function sync_clear_sales()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- TRUNCATE, not DELETE, so wiping a large history doesn't fire the
  -- per-row totals triggers thousands of times over — reset the summary
  -- tables directly instead, since there's nothing left to total.
  truncate sale_lines;
  truncate sales;
  truncate item_sales_totals;
  update sales_overall_totals set count = 0, revenue = 0 where key = 'all';
end;
$$;

-- ============== per-domain instant replace functions ==============
-- Every button that adds/edits/deletes items, categories, suppliers,
-- purchases, cashiers, held sales, shifts, or settings calls one of these
-- immediately — each only touches its own table, so editing inventory never
-- has to resend sales history (and vice versa).

create or replace function sync_replace_items(items jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from items where true;
  insert into items (id, name, barcode, category, price, stock, unit, low_stock)
  select x->>'id', x->>'name', coalesce(x->>'barcode',''), coalesce(x->>'category',''),
         coalesce((x->>'price')::numeric,0), coalesce((x->>'stock')::numeric,0),
         coalesce(x->>'unit',''), coalesce((x->>'lowStock')::numeric,0)
  from jsonb_array_elements(items) x;
end;
$$;

create or replace function sync_replace_categories(categories jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from categories where true;
  insert into categories (name)
  select jsonb_array_elements_text(categories);
end;
$$;

create or replace function sync_replace_suppliers(suppliers jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from suppliers where true;
  insert into suppliers (id, name, contact, address)
  select x->>'id', x->>'name', coalesce(x->>'contact',''), coalesce(x->>'address','')
  from jsonb_array_elements(suppliers) x;
end;
$$;

create or replace function sync_replace_cashiers(cashiers jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from cashiers where true;
  insert into cashiers (id, name, pin)
  select x->>'id', x->>'name', coalesce(x->>'pin','')
  from jsonb_array_elements(cashiers) x;
end;
$$;

create or replace function sync_replace_purchases(purchases jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from purchases where true;
  insert into purchases (id, date, supplier_id, supplier_name, item_id, item_name, qty, cost, total, notes, proof_data_url, proof_name)
  select x->>'id',
         nullif(x->>'date','')::date,
         x->>'supplierId', x->>'supplierName', x->>'itemId', x->>'itemName',
         (x->>'qty')::numeric, (x->>'cost')::numeric, (x->>'total')::numeric, coalesce(x->>'notes',''),
         x->>'proof', x->>'proofName'
  from jsonb_array_elements(purchases) x;
end;
$$;

create or replace function sync_replace_held_sales(held_sales jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from held_sales_cart where true;
  delete from held_sales where true;
  insert into held_sales (id, date, customer, discount, tax, cashier)
  select x->>'id', (x->>'date')::timestamptz, x->>'customer', (x->>'discount')::numeric, (x->>'tax')::numeric, x->>'cashier'
  from jsonb_array_elements(held_sales) x;

  insert into held_sales_cart (held_id, item_id, qty)
  select h->>'id', c->>'itemId', (c->>'qty')::numeric
  from jsonb_array_elements(held_sales) h,
       jsonb_array_elements(coalesce(h->'cart','[]'::jsonb)) c;
end;
$$;

create or replace function sync_replace_shifts(shifts jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from shifts where true;
  insert into shifts (id, cashier_name, start, "end", opening_cash, cash_sales, card_sales, wallet_sales, cash_refunds, txn_count, expected_cash, actual_cash, difference, notes)
  select x->>'id', x->>'cashierName', (x->>'start')::timestamptz, (x->>'end')::timestamptz,
         (x->>'openingCash')::numeric, (x->>'cashSales')::numeric, (x->>'cardSales')::numeric, (x->>'walletSales')::numeric,
         (x->>'cashRefunds')::numeric, (x->>'txnCount')::integer, (x->>'expectedCash')::numeric,
         (x->>'actualCash')::numeric, (x->>'difference')::numeric, coalesce(x->>'notes','')
  from jsonb_array_elements(shifts) x;
end;
$$;

create or replace function sync_replace_active_shift(active_shift jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from active_shift where true;
  if active_shift is not null and active_shift != 'null'::jsonb then
    insert into active_shift (id, cashier_id, cashier_name, start, opening_cash)
    values (
      active_shift->>'id',
      active_shift->>'cashierId',
      active_shift->>'cashierName',
      (active_shift->>'start')::timestamptz,
      (active_shift->>'openingCash')::numeric
    );
  end if;
end;
$$;

create or replace function sync_replace_settings(settings jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from settings where true;
  insert into settings (key, value)
  select k, v
  from jsonb_each_text(settings) as t(k, v);
end;
$$;

-- ============== grant access ONLY to the functions above ==============

grant execute on function sync_push(jsonb) to anon;
grant execute on function sync_pull_sales_range(timestamptz, timestamptz, integer) to anon;
grant execute on function sync_pull() to anon;
grant execute on function sync_append_sale(jsonb, integer) to anon;
grant execute on function sync_append_sales_batch(jsonb) to anon;
grant execute on function sync_append_refund(jsonb) to anon;
grant execute on function sync_clear_sales() to anon;
grant execute on function sync_replace_items(jsonb) to anon;
grant execute on function sync_replace_categories(jsonb) to anon;
grant execute on function sync_replace_suppliers(jsonb) to anon;
grant execute on function sync_replace_cashiers(jsonb) to anon;
grant execute on function sync_replace_purchases(jsonb) to anon;
grant execute on function sync_replace_held_sales(jsonb) to anon;
grant execute on function sync_replace_shifts(jsonb) to anon;
grant execute on function sync_replace_active_shift(jsonb) to anon;
grant execute on function sync_replace_settings(jsonb) to anon;
