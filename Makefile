HOSTNAME   = vulcan
REMOTES	   = hermes athena
MAX_AGE	   = 14d
CACHE	   = /Users/johnw/tank/Cache
ROOTS	   = /nix/var/nix/gcroots/per-user/johnw/shells
ENVS	   = emacs26Env emacsERCEnv ledgerPy2Env ledgerPy3Env # emacsHEADEnv
NIX_CONF   = $(HOME)/src/nix
MAKE_REC   = make -C $(NIX_CONF) NIX_CONF=$(NIX_CONF)
GIT_DATE   = git --git-dir=nixpkgs/.git show -s --format=%cd --date=format:%Y%m%d_%H%M%S
GIT_REMOTE = jwiegley

# Lazily evaluated variables; expensive to compute, but we only want it do it
# when first necessary.
HEAD_DATE  = $(eval HEAD_DATE := $(shell $(GIT_DATE) HEAD))$(HEAD_DATE)
LKG_DATE   = $(eval LKG_DATE  := $(shell $(GIT_DATE) last-known-good))$(LKG_DATE)

PROJS	   = $(eval PROJS     :=					\
	$(shell find $(HOME)/src $(HOME)/dfinity $(HOME)/Documents	\
		     -name .envrc					\
		  \! -path '*/nix/nixpkgs/*'				\
		  \! -path '*/notes/gists/*'				\
		     -type f						\
		     -printf '%h '))$(PROJS)

ifeq ($(NOCACHE),true)
NIXOPTS	   = --option build-use-substitutes false	\
	     --option substituters ''			\
	     --option builders ''
else
NIXOPTS	   =
endif
NIXPATH	   = $(NIX_PATH):localconfig=$(NIX_CONF)/config/$(HOSTNAME).nix
NIX	   = PATH=$(BUILD_PATH)/sw/bin:$(PATH) NIX_PATH=$(NIXPATH) nix

BUILD_ARGS = $(NIXOPTS) --keep-going --argstr version $(HEAD_DATE)
ifeq ($(REALBUILDPATH),true)
BUILD_PATH = $(eval BUILD_PATH :=					\
		$(shell echo NIX_PATH=$(NIXPATH) nix-build $(BUILD_ARGS)))$(BUILD_PATH)
else
BUILD_PATH = /run/current-system
endif

DARWIN_REBUILD = $(BUILD_PATH)/sw/bin/darwin-rebuild
HOME_MANAGER   = $(BUILD_PATH)/sw/bin/home-manager

all: rebuild

define make_broadcast
    for host in $(REMOTES); do				\
	ssh $$host "$(MAKE_REC) HOSTNAME=$$host $(1)";	\
    done
endef

%-all: %
	$(call make_broadcast,$<)

tools:
	@PATH=$(BUILD_PATH)/sw/bin:$(PATH)	\
	    which				\
		field				\
		find				\
		git				\
		head				\
		make				\
		nix-build			\
		nix-env				\
		sort				\
		sudo				\
		uniq

build:
	NIX_PATH=$(NIXPATH) nix build -f . $(BUILD_ARGS)
	@rm -f result*

darwin-switch:
	PATH=$(BUILD_PATH)/sw/bin:$(PATH) \
	NIX_PATH=$(NIXPATH) \
	    $(DARWIN_REBUILD) switch -Q
	@echo "Darwin generation: $$($(DARWIN_REBUILD) --list-generations | tail -1)"

home-switch:
	PATH=$(BUILD_PATH)/sw/bin:$(PATH) \
	NIX_PATH=$(NIXPATH) \
	HOME_MANAGER_CONFIG=$(NIX_CONF)/config/home.nix \
	    $(HOME_MANAGER) switch
	@echo "Home generation: $$($(HOME_MANAGER) generations | head -1)"
	@for file in $(HOME)/.config/fetchmail/config		\
		    $(HOME)/.config/fetchmail/config-lists; do	\
	    cp -pL $$file $$file.copy;				\
	    chmod 0600 $$file.copy;				\
	done

home-news:
	PATH=$(BUILD_PATH)/sw/bin:$(PATH)		\
	NIX_PATH=$(NIXPATH)				\
	HOME_MANAGER_CONFIG=$(NIX_CONF)/config/home.nix	\
	    $(HOME_MANAGER) news

switch: darwin-switch home-switch

rebuild: build switch env

opts:
	@echo export NIXOPTS=$(NIXOPTS)
	@echo export NIX_PATH=$(NIXPATH)

env:
	@for i in $(ENVS); do			\
	    echo Updating $$i;			\
	    NIX_PATH=$(NIXPATH)			\
	    nix-env -f '<darwin>' -u --leq	\
		-Q -k $(NIXOPTS) -A pkgs.$$i ;	\
	done
	@echo "Nix generation: $$(nix-env --list-generations | tail -1)"

projs:
	@for i in $(PROJS); do			\
	    echo "proj: $$i";			\
	done

shells:
	@for i in $(PROJS); do					\
	    cd $$i;						\
	    echo;						\
	    echo Building shell env for $$i;			\
	    echo;						\
	    NIX_PATH=$(NIXPATH) direnv export zsh > /dev/null	\
		|| echo "Failed to build direnv environment";	\
	done

pull:
	(cd darwin		   && git pull --rebase)
	(cd home-manager	   && git pull --rebase)
	(cd overlays/emacs-overlay && git pull --rebase)
	(cd nixpkgs		   && git pull --rebase)

tag-before:
	git --git-dir=nixpkgs/.git branch -f before-update HEAD

tag-working:
	git --git-dir=nixpkgs/.git branch -f last-known-good before-update
	git --git-dir=nixpkgs/.git branch -D before-update
	git --git-dir=nixpkgs/.git tag -f known-good-$(LKG_DATE) last-known-good

mirror:
	git --git-dir=nixpkgs/.git push $(GIT_REMOTE) -f master:master
	git --git-dir=nixpkgs/.git push $(GIT_REMOTE) -f unstable:unstable
	git --git-dir=nixpkgs/.git push $(GIT_REMOTE) -f last-known-good:last-known-good
	git --git-dir=nixpkgs/.git push -f --tags $(GIT_REMOTE)
	git --git-dir=darwin/.git push --mirror $(GIT_REMOTE)
	git --git-dir=home-manager/.git push --mirror $(GIT_REMOTE)
	git --git-dir=overlays/emacs-overlay/.git push --mirror $(GIT_REMOTE)

working: tag-working mirror

update: tag-before pull build switch env working

check:
	nix-store --verify --repair --check-contents

sizes:
	sizes /nix/store

copy-nix:
	@for host in $(REMOTES); do							\
	    PATH=$(BUILD_PATH)/sw/bin:$(PATH)						\
	    NIX_PATH=$(NIXPATH)								\
		nix copy --no-check-sigs --keep-going --to ssh://$$host $(BUILD_PATH);	\
	done

copy: copy-nix
	for host in $(REMOTES); do push -h $(HOSTNAME) -f src $$host; done

define find_defaults
    find $(PROJS) -path '*/.direnv/default'
endef

defaults:
	$(find_defaults)

copy-shells:
	for host in $(REMOTES); do					\
	    $(NIX) copy --no-check-sigs --keep-going --to ssh://$$host	\
		$(shell $(find_defaults)				\
		    | while read dir; do				\
			  ls $$dir/ | while read file ; do		\
			      readlink $$dir/$$file;			\
			  done ;					\
		      done | sort | uniq);				\
	done

cache:
	-test -d $(CACHE) &&					\
	(find /nix/store -maxdepth 1 -type f			\
	    \( -name '*.dmg' -o					\
	       -name '*.zip' -o					\
	       -name '*.pkg' -o					\
	       -name '*.el'  -o					\
	       -name '*.7z'  -o					\
	       -name '*gz'   -o					\
	       -name '*xz'   -o					\
	       -name '*bz2'  -o					\
	       -name '*.tar' \) -print0				\
	    | parallel -0 nix copy --to file://$(CACHE))

remove-build-products:
	find $(HOME)/Documents $(HOME)/src		\
	    \( -name 'dist' -type d -o			\
	       -name 'dist-newstyle' -type d -o		\
	       -name '.ghc.*' -o			\
	       -name 'cabal.project.local*' -type f -o	\
	       -name '.cargo-home' -type d -o		\
	       -name 'target' -type d -o		\
	       -name 'result*' -type l \) -print0	\
	    | xargs -P4 -0 /bin/rm -fr

remove-direnvs:
	find $(HOME)/Documents $(HOME)/src $(HOME)/.Trash	\
	    \( -name '.direnv' -type d \) -print0		\
	    | xargs -P4 -0 /bin/rm -fr

gc:
	nix-env --delete-generations					\
	    $(shell nix-env --list-generations | field 1 | head -n -14)
	nix-env -p /nix/var/nix/profiles/system --delete-generations	\
	    $(shell nix-env -p /nix/var/nix/profiles/system		\
				 --list-generations | field 1 | head -n -14)
	nix-collect-garbage --delete-older-than $(MAX_AGE)

gc-old: remove-build-products remove-direnvs
	nix-env --delete-generations					\
	    $(shell nix-env --list-generations | field 1 | head -n -1)
	nix-env -p /nix/var/nix/profiles/system --delete-generations	\
	    $(shell nix-env -p /nix/var/nix/profiles/system		\
				 --list-generations | field 1 | head -n -1)
	nix-collect-garbage --delete-old

clean: gc-all check-all

fullclean: gc-old-all check-all
