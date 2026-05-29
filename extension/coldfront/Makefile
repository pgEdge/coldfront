MODULE_big  = coldfront
OBJS        = src/coldfront.o

# Link libpq directly: the C XactCallback drains pending bakery releases
# via a libpq loopback connection (SPI is unsafe at XACT_EVENT_COMMIT/ABORT
# because the surrounding tx is finalizing). PGXS adds the server include
# path; we additionally need the client include path for libpq-fe.h.
PG_CONFIG  ?= pg_config
PG_CPPFLAGS = -I$(shell $(PG_CONFIG) --includedir)
SHLIB_LINK  = -lpq

EXTENSION   = coldfront
DATA        = coldfront--0.1.sql
REGRESS     = load_order update_unregistered_view update_heap_table \
              update_hot_via_view update_cold_via_view update_ambiguous_rejected \
              returning_literal_in_where cast_literal_in_value \
              classify_between_in_or allow_mixed_writes \
              dollar_quote_in_value mixed_case_identifier \
              cast_in_dquoted_identifier \
              ddl_noop_unregistered ddl_block_drop ddl_block_truncate \
              ddl_add_column ddl_drop_column ddl_alter_column_type \
              ddl_rename_column ddl_rename_table ddl_rename_view \
              ddl_partition_passthrough bakery_wraps_cold_writes
REGRESS_OPTS = --inputdir=test --outputdir=test

PG_CONFIG  ?= pg_config
PGXS       := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
