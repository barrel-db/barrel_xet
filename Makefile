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
	$(REBAR) as test do eunit, ct, cover

check: fmt-check compile xref lint eunit proper ct dialyzer

fixtures:
	sh scripts/fetch_fixtures.sh

release:
	$(REBAR) as prod release

smoke:
	bash scripts/smoke_release.sh
