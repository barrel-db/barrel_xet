REBAR ?= rebar3

.PHONY: all compile clean fmt fmt-check lint eunit ct proper xref dialyzer cover check fixtures

all: compile

compile:
	$(REBAR) compile

clean:
	$(REBAR) clean

fmt:
	$(REBAR) fmt

fmt-check:
	$(REBAR) fmt --check

lint:
	$(REBAR) lint

eunit:
	$(REBAR) eunit

ct:
	$(REBAR) ct

proper:
	$(REBAR) as test proper

xref:
	$(REBAR) xref

dialyzer:
	$(REBAR) dialyzer

cover:
	$(REBAR) as test cover

# proper joins check in Phase 1, once the first prop_* module exists.
check: fmt-check compile xref lint eunit ct dialyzer

fixtures:
	sh scripts/fetch_fixtures.sh
