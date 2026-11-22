# carbon

An active record library for Echo, on top of hydrahon. Three drivers ship today: MySQL and MariaDB
(`drivers/mysql`), PostgreSQL (`drivers/pgsql`) and SQLite (`drivers/sqlite`, on libsqlite and the
system's libsqlite3).

```bash
echoc build
echoc test
```

## Install

carbon, and a driver as a package inside it. epm vendors the repo once, at one release, so the
two always match:

```echo
#[requires: "echopack/carbon" { version: "^0.1.3", source: git "https://github.com/echopack/carbon" }]
#[requires: "echopack/carbon/drivers/mysql" { version: "^0.1.3", source: git "https://github.com/echopack/carbon" }]
// or, for PostgreSQL, which arrived in 0.1.4
#[requires: "echopack/carbon/drivers/pgsql" { version: "^0.1.4", source: git "https://github.com/echopack/carbon" }]
// or SQLite, with carbon::ddl::Sqlite() as the grammar
#[requires: "echopack/carbon/drivers/sqlite" { version: "^0.2", source: git "https://github.com/echopack/carbon" }]
```

Then `epm install`. carbongen comes along: `epm run carbongen`.

## Migrations

A migration is a class marked `#[carbon::migration]` with an id that starts with when it was
written. carbongen lists every one in the namespace's `Carbon::migrations()`, so they are compiled
into the app: there are no SQL files to ship.

```echo
#[carbon::migration: '20261029120000_create_users']
public class CreateUsers : carbon::Migration
{
    public function up(carbon::Migrating $m) : status<carbon::Error>
    {
        return $m->create(carbon::ddl::Table('users')
            ->id()
            ->string('email', 190, $unique: true)
            ->bool('admin', $default: false)
            ->timestamps());
    }

    // optional: without it the migration's batch cannot be rolled back
    public function down(carbon::Migrating $m) : status<carbon::Error>
    {
        return $m->drop('users');
    }
}
```

Run them with a `carbon::Migrator`, in a deploy step or at startup:

```echo
carbon::Migrator $migrator = carbon::Migrator($db, blog::Carbon::migrations(), carbon::ddl::Mysql());
array<string> $ran = guard $migrator->up();     // everything pending, as one batch
carbon::migrate::Report $r = guard $migrator->status();
guard $migrator->down();                        // the last batch, newest first
```

The migrator records what ran in `carbon_migrations` and holds a lock while it works (MySQL's
`GET_LOCK`, an advisory lock on PostgreSQL), so two copies of the app starting together don't
migrate twice. Schema changes come from `carbon::ddl` (`Table`, `Alter`) and are spelled per
database by a grammar: `carbon::ddl::Mysql()` or `carbon::ddl::Postgres()`. `$m->run(sql)` is
there for anything the grammar doesn't cover.

MySQL commits every schema change on its own, so a migration that fails halfway keeps what it
changed before failing. Keep each migration to one schema change. PostgreSQL runs each migration
and its `carbon_migrations` row in one transaction: it lands whole or not at all.

## Times

A field can be a `time::timestamp`, a `calendar::DateTime` or a `calendar::Date`
([echopack/calendar](https://github.com/echopack/calendar)), and carbongen maps it with no
attribute. A timestamp is an instant, so it goes into a DATETIME (a TIMESTAMP on PostgreSQL) as
UTC and comes back the same way; a `calendar::DateTime` is a wall clock and goes in as written; a `calendar::Date` is a DATE.
hydrahon's own `Date`, `DateTime` and `Time` work as before.

```echo
#[carbon::created]
public time::timestamp? $createdAt = null;
#[carbon::updated]
public calendar::DateTime? $updatedAt = null;
public calendar::Date $due;
```

Created, updated and deleted stamps come from the `DB`'s clock, a `calendar::Clock`. Give the app
the same one and read the time through carbon, so a test that moves the clock moves both:

```echo
calendar::ManualClock $clock = calendar::ManualClock(time::timestamp::from_unix_secs(1700000000));
carbon::DB $db = carbon::DB($source, clock: $clock);

time::timestamp $cut = $session->now() - time::duration::hours(24);   // whole seconds
array<Post> $recent = guard $posts->find()->where(PostTable::$createdAt >= $cut)->get();
```

Columns stay hydrahon terms, and carbon adds the comparisons and `$values[column] = value`
assignments for the three types. Where hydrahon wants a value of its own, convert with
`carbon::Temporal::stored($t)`. A stored value calendar cannot hold, such as MySQL's zero date,
fails to read with `Problem::range`.

## Threads

One `DB` serves every thread of an app. Build it on a pooled source, wire it on one thread, then
`seal()` it: from there on the repositories, stores, observers and listeners are only read, so
threads share the `DB` without a lock. Each thread, request or job works in a session of its own,
and each session takes a connection of its own from the pool with its first statement.

```echo
carbon::mysql::Source $source = carbon::mysql::Source(
    guard mysql::Options::parse($url),
    mysql::PoolOptions($max: 16),
);
carbon::DB $db = carbon::DB($source);
guard $db->register<PostRepository>();
guard blog::Carbon::check($db);     // makes every store, which seal() needs
$db->seal();

thread::handle $w = guard thread::spawn(function() : void {
    carbon::Session $s = $db->scoped();
    PostRepository $posts = guard $s->repo<PostRepository>();
    Post? $post = guard $posts->get(42);
});
```

After `seal()`, `register` is refused with `.sealed`; `observe`, `listen`, `schema` and a store
that was never made stop the program, because they are wiring done too late. A session, the root
session included, and the models it loads belong to one thread. So does a `DB` on one driver,
`DB($driver)`: its one connection serves one thread. A listener or observer added to a shared
`DB` is called from every thread, so it has to be `#[atomic]` and keep its state behind a lock,
as `carbon::listen::Log` does.

carbongen marks the table classes it writes `#[atomic]`: a model's store keeps one table and every
thread's sessions share it. A schema written by hand needs the same mark.

## PostgreSQL

`carbon::pgsql` is the same shape as `carbon::mysql`, on
[libpgsql](https://github.com/echolang/libpgsql): a `Driver` for one connection, a `Source` for a
pool.

```echo
carbon::pgsql::Source $source = guard carbon::pgsql::Source::parse('postgres://app:secret@127.0.0.1/blog');
carbon::DB $db = carbon::DB($source);
carbon::Migrator $migrator = carbon::Migrator($db, blog::Carbon::migrations(), carbon::ddl::Postgres());
```

Keys of new rows come back through `RETURNING`, and an UPDATE counts the rows it matched, so a
stale write is noticed without any option. Statements with parameters are prepared once per
connection and read in binary after that.

What changes from MySQL:

- An error inside a transaction aborts it. Catching a `.duplicate` and carrying on in the same
  transaction works on MySQL, not here: let the transaction fail and run it again.
- The grammar writes `id()` as `GENERATED BY DEFAULT AS IDENTITY`, `json` as `JSONB`, `tinyint`
  as `SMALLINT` and `time` as `INTERVAL`, which holds a negative duration or one past a day as
  MySQL's TIME does. An unsigned column becomes a signed one with `CHECK (col >= 0)`. Indexes are
  statements of their own after the `CREATE TABLE`, and `modify` changes only a column's type,
  NULL, default and whether it counts up. Shrinking a string column fails on a value that is
  too long instead of cutting it.
- An identity doesn't notice rows inserted with keys of their own. After a seed that writes ids,
  call `$m->advance('users')` in the migration, or the next key it counts collides. On MySQL it
  runs nothing.
- PostgreSQL doesn't index a foreign key column for you. Add the index in the migration.
- libpgsql has no TLS yet: `sslmode=require` is refused when connecting.

`drivers/pgsql/scripts/test-live.sh` runs the blog example against a PostgreSQL in Docker.
