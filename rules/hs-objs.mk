
define hs-objs  # args: $1 = dir, $2 = distdir, $3 = way
$1_$2_$3_HS_OBJS = $$(patsubst %,$1/$2/build/%.$$($3_osuf),$$($1_$2_SLASH_MODS))
$1_$2_$3_HI      = $$(patsubst %,$1/$2/build/%.$$($3_hisuf),$$($1_$2_SLASH_MODS))
endef