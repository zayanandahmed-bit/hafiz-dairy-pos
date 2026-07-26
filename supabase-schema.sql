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
-- direct table access is granted to anyone. The only way in or out is through
-- the two functions below (sync_push / sync_pull), which run with elevated
-- privileges (SECURITY DEFINER) but only do exactly what they're written to
-- do. This means even someone who gets your anon key can only call these two
-- functions — they can't run arbitrary queries against your tables.
--
-- Every save in the app sends the FULL current dataset, and sync_push wipes
-- and rewrites each table to match inside a single transaction, so the
-- database is always an exact, consistent mirror of the app's data.

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
    delete from sale_lines where true;
    delete from sales where true;
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

-- ============== sync_pull: read everything back as one JSON object ==============

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

    'sales', coalesce((select jsonb_agg(
      jsonb_build_object(
        'id', s.id, 'receiptNo', s.receipt_no, 'date', s.date, 'customer', s.customer,
        'cashier', s.cashier, 'payment', s.payment, 'cash', s.cash, 'subtotal', s.subtotal,
        'discountPct', s.discount_pct, 'discountAmt', s.discount_amt, 'taxPct', s.tax_pct,
        'taxAmt', s.tax_amt, 'grand', s.grand,
        'lines', coalesce((select jsonb_agg(jsonb_build_object(
          'itemId', sl.item_id, 'name', sl.item_name, 'barcode', sl.barcode,
          'price', sl.price, 'qty', sl.qty, 'unit', sl.unit, 'subtotal', sl.subtotal
        )) from sale_lines sl where sl.sale_id = s.id), '[]'::jsonb)
      )
    ) from sales s), '[]'::jsonb),

    'refunds', coalesce((select jsonb_agg(
      jsonb_build_object(
        'id', r.id, 'saleId', r.sale_id, 'receiptNo', r.receipt_no, 'date', r.date,
        'total', r.total, 'reason', r.reason, 'cashier', r.cashier,
        'lines', coalesce((select jsonb_agg(jsonb_build_object(
          'itemId', rl.item_id, 'name', rl.item_name, 'qty', rl.qty,
          'price', rl.price, 'refundAmount', rl.refund_amount
        )) from refund_lines rl where rl.refund_id = r.id), '[]'::jsonb)
      )
    ) from refunds r), '[]'::jsonb),

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

-- ============== grant access ONLY to the two functions above ==============

grant execute on function sync_push(jsonb) to anon;
grant execute on function sync_pull() to anon;
