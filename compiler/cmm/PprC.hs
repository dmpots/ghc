{-# OPTIONS -w #-}
-- The above warning supression flag is a temporary kludge.
-- While working on this module you are encouraged to remove it and fix
-- any warnings in the module. See
--     http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle#Warnings
-- for details

-----------------------------------------------------------------------------
--
-- Pretty-printing of Cmm as C, suitable for feeding gcc
--
-- (c) The University of Glasgow 2004-2006
--
-----------------------------------------------------------------------------

--
-- Print Cmm as real C, for -fvia-C
--
-- See wiki:Commentary/Compiler/Backends/PprC
--
-- This is simpler than the old PprAbsC, because Cmm is "macro-expanded"
-- relative to the old AbstractC, and many oddities/decorations have
-- disappeared from the data type.
--

-- ToDo: save/restore volatile registers around calls.

module PprC (
        writeCs,
        pprStringInCStyle 
  ) where

#include "HsVersions.h"

-- Cmm stuff
import BlockId
import OldCmm
import OldPprCmm	()	-- Instances only
import CLabel
import ForeignCall
import ClosureInfo

-- Utils
import DynFlags
import Unique
import UniqSet
import UniqFM
import FastString
import Outputable
import Constants
import BasicTypes
import CLabel

-- The rest
import Data.List
import Data.Bits
import Data.Char
import System.IO
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Word

import Data.Array.ST
import Control.Monad.ST

#if x86_64_TARGET_ARCH
import StaticFlags	( opt_Unregisterised )
#endif

#if defined(alpha_TARGET_ARCH) || defined(mips_TARGET_ARCH) || defined(mipsel_TARGET_ARCH) || defined(arm_TARGET_ARCH)
#define BEWARE_LOAD_STORE_ALIGNMENT
#endif

-- --------------------------------------------------------------------------
-- Top level

pprCs :: DynFlags -> [RawCmm] -> SDoc
pprCs dflags cmms
 = pprCode CStyle (vcat $ map (\c -> split_marker $$ pprC c) cmms)
 where
   split_marker
     | dopt Opt_SplitObjs dflags = ptext (sLit "__STG_SPLIT_MARKER")
     | otherwise     	         = empty

writeCs :: DynFlags -> Handle -> [RawCmm] -> IO ()
writeCs dflags handle cmms 
  = printForC handle (pprCs dflags cmms)

-- --------------------------------------------------------------------------
-- Now do some real work
--
-- for fun, we could call cmmToCmm over the tops...
--

pprC :: RawCmm -> SDoc
pprC (Cmm tops) = vcat $ intersperse blankLine $ map pprTop tops

--
-- top level procs
-- 
pprTop :: RawCmmTop -> SDoc
pprTop (CmmProc info clbl (ListGraph blocks)) =
    (if not (null info)
        then pprDataExterns info $$
             pprWordArray (entryLblToInfoLbl clbl) info
        else empty) $$
    (case blocks of
        [] -> empty
         -- the first block doesn't get a label:
        (BasicBlock _ stmts : rest) -> vcat [
	   blankLine,
	   extern_decls,
           (if (externallyVisibleCLabel clbl)
                    then mkFN_ else mkIF_) (pprCLabel clbl) <+> lbrace,
           nest 8 temp_decls,
           nest 8 mkFB_,
           nest 8 (vcat (map pprStmt stmts)) $$
              vcat (map pprBBlock rest),
           nest 8 mkFE_,
           rbrace ]
    )
  where
	(temp_decls, extern_decls) = pprTempAndExternDecls blocks 


-- Chunks of static data.

-- We only handle (a) arrays of word-sized things and (b) strings.

pprTop (CmmData _section _ds@[CmmDataLabel lbl, CmmString str]) = 
  hcat [
    pprLocalness lbl, ptext (sLit "char "), pprCLabel lbl,
    ptext (sLit "[] = "), pprStringInCStyle str, semi
  ]

pprTop (CmmData _section _ds@[CmmDataLabel lbl, CmmUninitialised size]) = 
  hcat [
    pprLocalness lbl, ptext (sLit "char "), pprCLabel lbl,
    brackets (int size), semi
  ]

pprTop top@(CmmData _section (CmmDataLabel lbl : lits)) = 
  pprDataExterns lits $$
  pprWordArray lbl lits  

-- Floating info table for safe a foreign call.
pprTop top@(CmmData _section d@(_ : _))
  | CmmDataLabel lbl : lits <- reverse d = 
  let lits' = reverse lits
  in pprDataExterns lits' $$
     pprWordArray lbl lits'

-- these shouldn't appear?
pprTop (CmmData _ _) = panic "PprC.pprTop: can't handle this data"

-- --------------------------------------------------------------------------
-- BasicBlocks are self-contained entities: they always end in a jump.
--
-- Like nativeGen/AsmCodeGen, we could probably reorder blocks to turn
-- as many jumps as possible into fall throughs.
--

pprBBlock :: CmmBasicBlock -> SDoc
pprBBlock (BasicBlock lbl stmts) = 
    if null stmts then
        pprTrace "pprC.pprBBlock: curious empty code block for" 
                        (pprBlockId lbl) empty
    else 
        nest 4 (pprBlockId lbl <> colon) $$
        nest 8 (vcat (map pprStmt stmts))

-- --------------------------------------------------------------------------
-- Info tables. Just arrays of words. 
-- See codeGen/ClosureInfo, and nativeGen/PprMach

pprWordArray :: CLabel -> [CmmStatic] -> SDoc
pprWordArray lbl ds
  = hcat [ pprLocalness lbl, ptext (sLit "StgWord")
         , space, pprCLabel lbl, ptext (sLit "[] = {") ] 
    $$ nest 8 (commafy (pprStatics ds))
    $$ ptext (sLit "};")

--
-- has to be static, if it isn't globally visible
--
pprLocalness :: CLabel -> SDoc
pprLocalness lbl | not $ externallyVisibleCLabel lbl = ptext (sLit "static ")
                 | otherwise = empty

-- --------------------------------------------------------------------------
-- Statements.
--

pprStmt :: CmmStmt -> SDoc

pprStmt stmt = case stmt of
    CmmNop       -> empty
    CmmComment s -> empty -- (hang (ptext (sLit "/*")) 3 (ftext s)) $$ ptext (sLit "*/")
                          -- XXX if the string contains "*/", we need to fix it
                          -- XXX we probably want to emit these comments when
                          -- some debugging option is on.  They can get quite
                          -- large.

    CmmAssign dest src -> pprAssign dest src

    CmmStore  dest src
 	| typeWidth rep == W64 && wordWidth /= W64
 	-> (if isFloatType rep then ptext (sLit "ASSIGN_DBL")
 			       else ptext (sLit ("ASSIGN_Word64"))) <> 
 	   parens (mkP_ <> pprExpr1 dest <> comma <> pprExpr src) <> semi

 	| otherwise
	-> hsep [ pprExpr (CmmLoad dest rep), equals, pprExpr src <> semi ]
	where
	  rep = cmmExprType src

    CmmCall (CmmCallee fn cconv) results args safety ret ->
        maybe_proto $$
	fnCall
	where
        cast_fn = parens (cCast (pprCFunType (char '*') cconv results args) fn)

        real_fun_proto lbl = char ';' <> 
                        pprCFunType (pprCLabel lbl) cconv results args <> 
                        noreturn_attr <> semi

        fun_proto lbl = ptext (sLit ";EF_(") <>
                         pprCLabel lbl <> char ')' <> semi

        noreturn_attr = case ret of
                          CmmNeverReturns -> text "__attribute__ ((noreturn))"
                          CmmMayReturn    -> empty

        -- See wiki:Commentary/Compiler/Backends/PprC#Prototypes
    	(maybe_proto, fnCall) = 
            case fn of
	      CmmLit (CmmLabel lbl) 
                | StdCallConv <- cconv ->
                    let myCall = pprCall (pprCLabel lbl) cconv results args safety
                    in (real_fun_proto lbl, myCall)
                        -- stdcall functions must be declared with
                        -- a function type, otherwise the C compiler
                        -- doesn't add the @n suffix to the label.  We
                        -- can't add the @n suffix ourselves, because
                        -- it isn't valid C.
                | CmmNeverReturns <- ret ->
                    let myCall = pprCall (pprCLabel lbl) cconv results args safety
                    in (real_fun_proto lbl, myCall)
                | not (isMathFun lbl) ->
                    let myCall = braces (
                                     pprCFunType (char '*' <> text "ghcFunPtr") cconv results args <> semi
                                  $$ text "ghcFunPtr" <+> equals <+> cast_fn <> semi
                                  $$ pprCall (text "ghcFunPtr") cconv results args safety <> semi
                                 )
                    in (fun_proto lbl, myCall)
	      _ -> 
                   (empty {- no proto -},
                    pprCall cast_fn cconv results args safety <> semi)
			-- for a dynamic call, no declaration is necessary.

    CmmCall (CmmPrim op) results args safety _ret ->
	pprCall ppr_fn CCallConv results args safety
	where
    	ppr_fn = pprCallishMachOp_for_C op

    CmmBranch ident          -> pprBranch ident
    CmmCondBranch expr ident -> pprCondBranch expr ident
    CmmJump lbl _params      -> mkJMP_(pprExpr lbl) <> semi
    CmmSwitch arg ids        -> pprSwitch arg ids

pprCFunType :: SDoc -> CCallConv -> HintedCmmFormals -> HintedCmmActuals -> SDoc
pprCFunType ppr_fn cconv ress args
  = res_type ress <+>
    parens (text (ccallConvAttribute cconv) <>  ppr_fn) <>
    parens (commafy (map arg_type args))
  where
	res_type [] = ptext (sLit "void")
	res_type [CmmHinted one hint] = machRepHintCType (localRegType one) hint

	arg_type (CmmHinted expr hint) = machRepHintCType (cmmExprType expr) hint

-- ---------------------------------------------------------------------
-- unconditional branches
pprBranch :: BlockId -> SDoc
pprBranch ident = ptext (sLit "goto") <+> pprBlockId ident <> semi


-- ---------------------------------------------------------------------
-- conditional branches to local labels
pprCondBranch :: CmmExpr -> BlockId -> SDoc
pprCondBranch expr ident 
        = hsep [ ptext (sLit "if") , parens(pprExpr expr) ,
                        ptext (sLit "goto") , (pprBlockId ident) <> semi ]


-- ---------------------------------------------------------------------
-- a local table branch
--
-- we find the fall-through cases
--
-- N.B. we remove Nothing's from the list of branches, as they are
-- 'undefined'. However, they may be defined one day, so we better
-- document this behaviour.
--
pprSwitch :: CmmExpr -> [ Maybe BlockId ] -> SDoc
pprSwitch e maybe_ids 
  = let pairs  = [ (ix, ident) | (ix,Just ident) <- zip [0..] maybe_ids ]
	pairs2 = [ (map fst as, snd (head as)) | as <- groupBy sndEq pairs ]
    in 
        (hang (ptext (sLit "switch") <+> parens ( pprExpr e ) <+> lbrace)
                4 (vcat ( map caseify pairs2 )))
        $$ rbrace

  where
    sndEq (_,x) (_,y) = x == y

    -- fall through case
    caseify (ix:ixs, ident) = vcat (map do_fallthrough ixs) $$ final_branch ix
	where 
	do_fallthrough ix =
                 hsep [ ptext (sLit "case") , pprHexVal ix wordWidth <> colon ,
                        ptext (sLit "/* fall through */") ]

	final_branch ix = 
	        hsep [ ptext (sLit "case") , pprHexVal ix wordWidth <> colon ,
                       ptext (sLit "goto") , (pprBlockId ident) <> semi ]

-- ---------------------------------------------------------------------
-- Expressions.
--

-- C Types: the invariant is that the C expression generated by
--
--	pprExpr e
--
-- has a type in C which is also given by
--
--	machRepCType (cmmExprType e)
--
-- (similar invariants apply to the rest of the pretty printer).

pprExpr :: CmmExpr -> SDoc
pprExpr e = case e of
    CmmLit lit -> pprLit lit


    CmmLoad e ty -> pprLoad e ty
    CmmReg reg      -> pprCastReg reg
    CmmRegOff reg 0 -> pprCastReg reg

    CmmRegOff reg i
	| i >  0    -> pprRegOff (char '+') i
	| otherwise -> pprRegOff (char '-') (-i)
      where
	pprRegOff op i' = pprCastReg reg <> op <> int i'

    CmmMachOp mop args -> pprMachOpApp mop args


pprLoad :: CmmExpr -> CmmType -> SDoc
pprLoad e ty
  | width == W64, wordWidth /= W64
  = (if isFloatType ty then ptext (sLit "PK_DBL")
	    	       else ptext (sLit "PK_Word64"))
    <> parens (mkP_ <> pprExpr1 e)

  | otherwise 
  = case e of
	CmmReg r | isPtrReg r && width == wordWidth && not (isFloatType ty)
		 -> char '*' <> pprAsPtrReg r

	CmmRegOff r 0 | isPtrReg r && width == wordWidth && not (isFloatType ty)
		      -> char '*' <> pprAsPtrReg r

	CmmRegOff r off | isPtrReg r && width == wordWidth
			, off `rem` wORD_SIZE == 0 && not (isFloatType ty)
	-- ToDo: check that the offset is a word multiple?
        --       (For tagging to work, I had to avoid unaligned loads. --ARY)
			-> pprAsPtrReg r <> brackets (ppr (off `shiftR` wordShift))

	_other -> cLoad e ty
  where
    width = typeWidth ty

pprExpr1 :: CmmExpr -> SDoc
pprExpr1 (CmmLit lit) 	  = pprLit1 lit
pprExpr1 e@(CmmReg _reg)  = pprExpr e
pprExpr1 other            = parens (pprExpr other)

-- --------------------------------------------------------------------------
-- MachOp applications

pprMachOpApp :: MachOp -> [CmmExpr] -> SDoc

pprMachOpApp op args
  | isMulMayOfloOp op
  = ptext (sLit "mulIntMayOflo") <> parens (commafy (map pprExpr args))
  where isMulMayOfloOp (MO_U_MulMayOflo _) = True
	isMulMayOfloOp (MO_S_MulMayOflo _) = True
	isMulMayOfloOp _ = False

pprMachOpApp mop args
  | Just ty <- machOpNeedsCast mop 
  = ty <> parens (pprMachOpApp' mop args)
  | otherwise
  = pprMachOpApp' mop args

-- Comparisons in C have type 'int', but we want type W_ (this is what
-- resultRepOfMachOp says).  The other C operations inherit their type
-- from their operands, so no casting is required.
machOpNeedsCast :: MachOp -> Maybe SDoc
machOpNeedsCast mop
  | isComparisonMachOp mop = Just mkW_
  | otherwise              = Nothing

pprMachOpApp' mop args
 = case args of
    -- dyadic
    [x,y] -> pprArg x <+> pprMachOp_for_C mop <+> pprArg y

    -- unary
    [x]   -> pprMachOp_for_C mop <> parens (pprArg x)

    _     -> panic "PprC.pprMachOp : machop with wrong number of args"

  where
	-- Cast needed for signed integer ops
    pprArg e | signedOp    mop = cCast (machRep_S_CType (typeWidth (cmmExprType e))) e
             | needsFCasts mop = cCast (machRep_F_CType (typeWidth (cmmExprType e))) e
 	     | otherwise    = pprExpr1 e
    needsFCasts (MO_F_Eq _)   = False
    needsFCasts (MO_F_Ne _)   = False
    needsFCasts (MO_F_Neg _)  = True
    needsFCasts (MO_F_Quot _) = True
    needsFCasts mop  = floatComparison mop

-- --------------------------------------------------------------------------
-- Literals

pprLit :: CmmLit -> SDoc
pprLit lit = case lit of
    CmmInt i rep      -> pprHexVal i rep

    CmmFloat f w       -> parens (machRep_F_CType w) <> str
        where d = fromRational f :: Double
              str | isInfinite d && d < 0 = ptext (sLit "-INFINITY")
                  | isInfinite d          = ptext (sLit "INFINITY")
                  | isNaN d               = ptext (sLit "NAN")
                  | otherwise             = text (show d)
                -- these constants come from <math.h>
                -- see #1861

    CmmBlock bid       -> mkW_ <> pprCLabelAddr (infoTblLbl bid)
    CmmHighStackMark   -> panic "PprC printing high stack mark"
    CmmLabel clbl      -> mkW_ <> pprCLabelAddr clbl
    CmmLabelOff clbl i -> mkW_ <> pprCLabelAddr clbl <> char '+' <> int i
    CmmLabelDiffOff clbl1 clbl2 i
        -- WARNING:
        --  * the lit must occur in the info table clbl2
        --  * clbl1 must be an SRT, a slow entry point or a large bitmap
        -- The Mangler is expected to convert any reference to an SRT,
        -- a slow entry point or a large bitmap
        -- from an info table to an offset.
        -> mkW_ <> pprCLabelAddr clbl1 <> char '+' <> int i

pprCLabelAddr lbl = char '&' <> pprCLabel lbl

pprLit1 :: CmmLit -> SDoc
pprLit1 lit@(CmmLabelOff _ _) = parens (pprLit lit)
pprLit1 lit@(CmmLabelDiffOff _ _ _) = parens (pprLit lit)
pprLit1 lit@(CmmFloat _ _)    = parens (pprLit lit)
pprLit1 other = pprLit other

-- ---------------------------------------------------------------------------
-- Static data

pprStatics :: [CmmStatic] -> [SDoc]
pprStatics [] = []
pprStatics (CmmStaticLit (CmmFloat f W32) : rest) 
  -- floats are padded to a word, see #1852
  | wORD_SIZE == 8, CmmStaticLit (CmmInt 0 W32) : rest' <- rest
  = pprLit1 (floatToWord f) : pprStatics rest'
  | wORD_SIZE == 4
  = pprLit1 (floatToWord f) : pprStatics rest
  | otherwise
  = pprPanic "pprStatics: float" (vcat (map (\(CmmStaticLit l) -> ppr (cmmLitType l)) rest))
pprStatics (CmmStaticLit (CmmFloat f W64) : rest)
  = map pprLit1 (doubleToWords f) ++ pprStatics rest
pprStatics (CmmStaticLit (CmmInt i W64) : rest)
  | wordWidth == W32
#ifdef WORDS_BIGENDIAN
  = pprStatics (CmmStaticLit (CmmInt q W32) : 
		CmmStaticLit (CmmInt r W32) : rest)
#else
  = pprStatics (CmmStaticLit (CmmInt r W32) : 
		CmmStaticLit (CmmInt q W32) : rest)
#endif
  where r = i .&. 0xffffffff
	q = i `shiftR` 32
pprStatics (CmmStaticLit (CmmInt i w) : rest)
  | w /= wordWidth
  = panic "pprStatics: cannot emit a non-word-sized static literal"
pprStatics (CmmStaticLit lit : rest)
  = pprLit1 lit : pprStatics rest
pprStatics (other : rest)
  = pprPanic "pprWord" (pprStatic other)

pprStatic :: CmmStatic -> SDoc
pprStatic s = case s of

    CmmStaticLit lit   -> nest 4 (pprLit lit)
    CmmAlign i         -> nest 4 (ptext (sLit "/* align */") <+> int i)
    CmmDataLabel clbl  -> pprCLabel clbl <> colon
    CmmUninitialised i -> nest 4 (mkC_ <> brackets (int i))

    -- these should be inlined, like the old .hc
    CmmString s'       -> nest 4 (mkW_ <> parens(pprStringInCStyle s'))


-- ---------------------------------------------------------------------------
-- Block Ids

pprBlockId :: BlockId -> SDoc
pprBlockId b = char '_' <> ppr (getUnique b)

-- --------------------------------------------------------------------------
-- Print a MachOp in a way suitable for emitting via C.
--

pprMachOp_for_C :: MachOp -> SDoc

pprMachOp_for_C mop = case mop of 

        -- Integer operations
        MO_Add          _ -> char '+'
        MO_Sub          _ -> char '-'
        MO_Eq           _ -> ptext (sLit "==")
        MO_Ne           _ -> ptext (sLit "!=")
        MO_Mul          _ -> char '*'

        MO_S_Quot       _ -> char '/'
        MO_S_Rem        _ -> char '%'
        MO_S_Neg        _ -> char '-'

        MO_U_Quot       _ -> char '/'
        MO_U_Rem        _ -> char '%'

        -- & Floating-point operations
        MO_F_Add        _ -> char '+'
        MO_F_Sub        _ -> char '-'
        MO_F_Neg        _ -> char '-'
        MO_F_Mul        _ -> char '*'
        MO_F_Quot       _ -> char '/'

        -- Signed comparisons
        MO_S_Ge         _ -> ptext (sLit ">=")
        MO_S_Le         _ -> ptext (sLit "<=")
        MO_S_Gt         _ -> char '>'
        MO_S_Lt         _ -> char '<'

        -- & Unsigned comparisons
        MO_U_Ge         _ -> ptext (sLit ">=")
        MO_U_Le         _ -> ptext (sLit "<=")
        MO_U_Gt         _ -> char '>'
        MO_U_Lt         _ -> char '<'

        -- & Floating-point comparisons
        MO_F_Eq         _ -> ptext (sLit "==")
        MO_F_Ne         _ -> ptext (sLit "!=")
        MO_F_Ge         _ -> ptext (sLit ">=")
        MO_F_Le         _ -> ptext (sLit "<=")
        MO_F_Gt         _ -> char '>'
        MO_F_Lt         _ -> char '<'

        -- Bitwise operations.  Not all of these may be supported at all
        -- sizes, and only integral MachReps are valid.
        MO_And          _ -> char '&'
        MO_Or           _ -> char '|'
        MO_Xor          _ -> char '^'
        MO_Not          _ -> char '~'
        MO_Shl          _ -> ptext (sLit "<<")
        MO_U_Shr        _ -> ptext (sLit ">>") -- unsigned shift right
        MO_S_Shr        _ -> ptext (sLit ">>") -- signed shift right

-- Conversions.  Some of these will be NOPs, but never those that convert
-- between ints and floats.
-- Floating-point conversions use the signed variant.
-- We won't know to generate (void*) casts here, but maybe from
-- context elsewhere

-- noop casts
        MO_UU_Conv from to | from == to -> empty
	MO_UU_Conv _from to  -> parens (machRep_U_CType to)

        MO_SS_Conv from to | from == to -> empty
	MO_SS_Conv _from to  -> parens (machRep_S_CType to)

        -- TEMPORARY: the old code didn't check this case, so let's leave it out
        -- to facilitate comparisons against the old output code.
        --MO_FF_Conv from to | from == to -> empty
	MO_FF_Conv _from to  -> parens (machRep_F_CType to)

	MO_SF_Conv _from to  -> parens (machRep_F_CType to)
	MO_FS_Conv _from to  -> parens (machRep_S_CType to)

        _ -> pprTrace "offending mop" (ptext $ sLit $ show mop) $
             panic "PprC.pprMachOp_for_C: unknown machop"

signedOp :: MachOp -> Bool	-- Argument type(s) are signed ints
signedOp (MO_S_Quot _)	 = True
signedOp (MO_S_Rem  _)	 = True
signedOp (MO_S_Neg  _)	 = True
signedOp (MO_S_Ge   _)	 = True
signedOp (MO_S_Le   _)	 = True
signedOp (MO_S_Gt   _)	 = True
signedOp (MO_S_Lt   _)	 = True
signedOp (MO_S_Shr  _)	 = True
signedOp (MO_SS_Conv _ _) = True
signedOp (MO_SF_Conv _ _) = True
signedOp _ = False

floatComparison :: MachOp -> Bool  -- comparison between float args
floatComparison (MO_F_Eq   _)	 = True
floatComparison (MO_F_Ne   _)	 = True
floatComparison (MO_F_Ge   _)	 = True
floatComparison (MO_F_Le   _)	 = True
floatComparison (MO_F_Gt   _)	 = True
floatComparison (MO_F_Lt   _)	 = True
floatComparison _ = False

-- ---------------------------------------------------------------------
-- tend to be implemented by foreign calls

pprCallishMachOp_for_C :: CallishMachOp -> SDoc

pprCallishMachOp_for_C mop 
    = case mop of
        MO_F64_Pwr  -> ptext (sLit "pow")
        MO_F64_Sin  -> ptext (sLit "sin")
        MO_F64_Cos  -> ptext (sLit "cos")
        MO_F64_Tan  -> ptext (sLit "tan")
        MO_F64_Sinh -> ptext (sLit "sinh")
        MO_F64_Cosh -> ptext (sLit "cosh")
        MO_F64_Tanh -> ptext (sLit "tanh")
        MO_F64_Asin -> ptext (sLit "asin")
        MO_F64_Acos -> ptext (sLit "acos")
        MO_F64_Atan -> ptext (sLit "atan")
        MO_F64_Log  -> ptext (sLit "log")
        MO_F64_Exp  -> ptext (sLit "exp")
        MO_F64_Sqrt -> ptext (sLit "sqrt")
        MO_F32_Pwr  -> ptext (sLit "powf")
        MO_F32_Sin  -> ptext (sLit "sinf")
        MO_F32_Cos  -> ptext (sLit "cosf")
        MO_F32_Tan  -> ptext (sLit "tanf")
        MO_F32_Sinh -> ptext (sLit "sinhf")
        MO_F32_Cosh -> ptext (sLit "coshf")
        MO_F32_Tanh -> ptext (sLit "tanhf")
        MO_F32_Asin -> ptext (sLit "asinf")
        MO_F32_Acos -> ptext (sLit "acosf")
        MO_F32_Atan -> ptext (sLit "atanf")
        MO_F32_Log  -> ptext (sLit "logf")
        MO_F32_Exp  -> ptext (sLit "expf")
        MO_F32_Sqrt -> ptext (sLit "sqrtf")
	MO_WriteBarrier -> ptext (sLit "write_barrier")

-- ---------------------------------------------------------------------
-- Useful #defines
--

mkJMP_, mkFN_, mkIF_ :: SDoc -> SDoc

mkJMP_ i = ptext (sLit "JMP_") <> parens i
mkFN_  i = ptext (sLit "FN_")  <> parens i -- externally visible function
mkIF_  i = ptext (sLit "IF_")  <> parens i -- locally visible


mkFB_, mkFE_ :: SDoc
mkFB_ = ptext (sLit "FB_") -- function code begin
mkFE_ = ptext (sLit "FE_") -- function code end

-- from includes/Stg.h
--
mkC_,mkW_,mkP_ :: SDoc

mkC_  = ptext (sLit "(C_)")        -- StgChar
mkW_  = ptext (sLit "(W_)")        -- StgWord
mkP_  = ptext (sLit "(P_)")        -- StgWord*

-- ---------------------------------------------------------------------
--
-- Assignments
--
-- Generating assignments is what we're all about, here
--
pprAssign :: CmmReg -> CmmExpr -> SDoc

-- dest is a reg, rhs is a reg
pprAssign r1 (CmmReg r2)
   | isPtrReg r1 && isPtrReg r2
   = hcat [ pprAsPtrReg r1, equals, pprAsPtrReg r2, semi ]

-- dest is a reg, rhs is a CmmRegOff
pprAssign r1 (CmmRegOff r2 off)
   | isPtrReg r1 && isPtrReg r2 && (off `rem` wORD_SIZE == 0)
   = hcat [ pprAsPtrReg r1, equals, pprAsPtrReg r2, op, int off', semi ]
  where
	off1 = off `shiftR` wordShift

	(op,off') | off >= 0  = (char '+', off1)
		  | otherwise = (char '-', -off1)

-- dest is a reg, rhs is anything.
-- We can't cast the lvalue, so we have to cast the rhs if necessary.  Casting
-- the lvalue elicits a warning from new GCC versions (3.4+).
pprAssign r1 r2
  | isFixedPtrReg r1             = mkAssign (mkP_ <> pprExpr1 r2)
  | Just ty <- strangeRegType r1 = mkAssign (parens ty <> pprExpr1 r2)
  | otherwise                    = mkAssign (pprExpr r2)
    where mkAssign x = if r1 == CmmGlobal BaseReg
                       then ptext (sLit "ASSIGN_BaseReg") <> parens x <> semi
                       else pprReg r1 <> ptext (sLit " = ") <> x <> semi

-- ---------------------------------------------------------------------
-- Registers

pprCastReg reg
   | isStrangeTypeReg reg = mkW_ <> pprReg reg
   | otherwise            = pprReg reg

-- True if (pprReg reg) will give an expression with type StgPtr.  We
-- need to take care with pointer arithmetic on registers with type
-- StgPtr.
isFixedPtrReg :: CmmReg -> Bool
isFixedPtrReg (CmmLocal _) = False
isFixedPtrReg (CmmGlobal r) = isFixedPtrGlobalReg r

-- True if (pprAsPtrReg reg) will give an expression with type StgPtr
-- JD: THIS IS HORRIBLE AND SHOULD BE RENAMED, AT THE VERY LEAST.
-- THE GARBAGE WITH THE VNonGcPtr HELPS MATCH THE OLD CODE GENERATOR'S OUTPUT;
-- I'M NOT SURE IF IT SHOULD REALLY STAY THAT WAY.
isPtrReg :: CmmReg -> Bool
isPtrReg (CmmLocal _) 		    = False
isPtrReg (CmmGlobal (VanillaReg n VGcPtr)) = True -- if we print via pprAsPtrReg
isPtrReg (CmmGlobal (VanillaReg n VNonGcPtr)) = False --if we print via pprAsPtrReg
isPtrReg (CmmGlobal reg)	    = isFixedPtrGlobalReg reg

-- True if this global reg has type StgPtr
isFixedPtrGlobalReg :: GlobalReg -> Bool
isFixedPtrGlobalReg Sp 		= True
isFixedPtrGlobalReg Hp 		= True
isFixedPtrGlobalReg HpLim	= True
isFixedPtrGlobalReg SpLim	= True
isFixedPtrGlobalReg _ 		= False

-- True if in C this register doesn't have the type given by 
-- (machRepCType (cmmRegType reg)), so it has to be cast.
isStrangeTypeReg :: CmmReg -> Bool
isStrangeTypeReg (CmmLocal _) 	= False
isStrangeTypeReg (CmmGlobal g) 	= isStrangeTypeGlobal g

isStrangeTypeGlobal :: GlobalReg -> Bool
isStrangeTypeGlobal CurrentTSO		= True
isStrangeTypeGlobal CurrentNursery 	= True
isStrangeTypeGlobal BaseReg	 	= True
isStrangeTypeGlobal r 			= isFixedPtrGlobalReg r

strangeRegType :: CmmReg -> Maybe SDoc
strangeRegType (CmmGlobal CurrentTSO) = Just (ptext (sLit "struct StgTSO_ *"))
strangeRegType (CmmGlobal CurrentNursery) = Just (ptext (sLit "struct bdescr_ *"))
strangeRegType (CmmGlobal BaseReg) = Just (ptext (sLit "struct StgRegTable_ *"))
strangeRegType _ = Nothing

-- pprReg just prints the register name.
--
pprReg :: CmmReg -> SDoc
pprReg r = case r of
        CmmLocal  local  -> pprLocalReg local
        CmmGlobal global -> pprGlobalReg global
		
pprAsPtrReg :: CmmReg -> SDoc
pprAsPtrReg (CmmGlobal (VanillaReg n gcp)) 
  = WARN( gcp /= VGcPtr, ppr n ) char 'R' <> int n <> ptext (sLit ".p")
pprAsPtrReg other_reg = pprReg other_reg

pprGlobalReg :: GlobalReg -> SDoc
pprGlobalReg gr = case gr of
    VanillaReg n _ -> char 'R' <> int n  <> ptext (sLit ".w")
	-- pprGlobalReg prints a VanillaReg as a .w regardless
	-- Example:	R1.w = R1.w & (-0x8UL);
	--		JMP_(*R1.p);
    FloatReg   n   -> char 'F' <> int n
    DoubleReg  n   -> char 'D' <> int n
    LongReg    n   -> char 'L' <> int n
    Sp             -> ptext (sLit "Sp")
    SpLim          -> ptext (sLit "SpLim")
    Hp             -> ptext (sLit "Hp")
    HpLim          -> ptext (sLit "HpLim")
    CurrentTSO     -> ptext (sLit "CurrentTSO")
    CurrentNursery -> ptext (sLit "CurrentNursery")
    HpAlloc        -> ptext (sLit "HpAlloc")
    BaseReg        -> ptext (sLit "BaseReg")
    EagerBlackholeInfo -> ptext (sLit "stg_EAGER_BLACKHOLE_info")
    GCEnter1       -> ptext (sLit "stg_gc_enter_1")
    GCFun          -> ptext (sLit "stg_gc_fun")

pprLocalReg :: LocalReg -> SDoc
pprLocalReg (LocalReg uniq _) = char '_' <> ppr uniq

-- -----------------------------------------------------------------------------
-- Foreign Calls

pprCall :: SDoc -> CCallConv -> HintedCmmFormals -> HintedCmmActuals -> CmmSafety
	-> SDoc

pprCall ppr_fn cconv results args _
  | not (is_cish cconv)
  = panic "pprCall: unknown calling convention"

  | otherwise
  =
#if x86_64_TARGET_ARCH
	-- HACK around gcc optimisations.
	-- x86_64 needs a __DISCARD__() here, to create a barrier between
	-- putting the arguments into temporaries and passing the arguments
	-- to the callee, because the argument expressions may refer to
	-- machine registers that are also used for passing arguments in the
	-- C calling convention.
    (if (not opt_Unregisterised) 
	then ptext (sLit "__DISCARD__();") 
	else empty) $$
#endif
    ppr_assign results (ppr_fn <> parens (commafy (map pprArg args))) <> semi
  where 
     ppr_assign []           rhs = rhs
     ppr_assign [CmmHinted one hint] rhs
	 = pprLocalReg one <> ptext (sLit " = ")
		 <> pprUnHint hint (localRegType one) <> rhs
     ppr_assign _other _rhs = panic "pprCall: multiple results"

     pprArg (CmmHinted expr AddrHint)
   	= cCast (ptext (sLit "void *")) expr
	-- see comment by machRepHintCType below
     pprArg (CmmHinted expr SignedHint)
	= cCast (machRep_S_CType $ typeWidth $ cmmExprType expr) expr
     pprArg (CmmHinted expr _other)
	= pprExpr expr

     pprUnHint AddrHint   rep = parens (machRepCType rep)
     pprUnHint SignedHint rep = parens (machRepCType rep)
     pprUnHint _          _   = empty

pprGlobalRegName :: GlobalReg -> SDoc
pprGlobalRegName gr = case gr of
    VanillaReg n _  -> char 'R' <> int n  -- without the .w suffix
    _               -> pprGlobalReg gr

-- Currently we only have these two calling conventions, but this might
-- change in the future...
is_cish CCallConv   = True
is_cish StdCallConv = True

-- ---------------------------------------------------------------------
-- Find and print local and external declarations for a list of
-- Cmm statements.
-- 
pprTempAndExternDecls :: [CmmBasicBlock] -> (SDoc{-temps-}, SDoc{-externs-})
pprTempAndExternDecls stmts 
  = (vcat (map pprTempDecl (uniqSetToList temps)), 
     vcat (map (pprExternDecl False{-ToDo-}) (Map.keys lbls)))
  where (temps, lbls) = runTE (mapM_ te_BB stmts)

pprDataExterns :: [CmmStatic] -> SDoc
pprDataExterns statics
  = vcat (map (pprExternDecl False{-ToDo-}) (Map.keys lbls))
  where (_, lbls) = runTE (mapM_ te_Static statics)

pprTempDecl :: LocalReg -> SDoc
pprTempDecl l@(LocalReg _ rep)
  = hcat [ machRepCType rep, space, pprLocalReg l, semi ]

pprExternDecl :: Bool -> CLabel -> SDoc
pprExternDecl in_srt lbl
  -- do not print anything for "known external" things
  | not (needsCDecl lbl) = empty
  | Just sz <- foreignLabelStdcallInfo lbl = stdcall_decl sz
  | otherwise =
	hcat [ visibility, label_type lbl,
	       lparen, pprCLabel lbl, text ");" ]
 where
  label_type lbl | isCFunctionLabel lbl = ptext (sLit "F_")
		 | otherwise		= ptext (sLit "I_")

  visibility
     | externallyVisibleCLabel lbl = char 'E'
     | otherwise		   = char 'I'

  -- If the label we want to refer to is a stdcall function (on Windows) then
  -- we must generate an appropriate prototype for it, so that the C compiler will
  -- add the @n suffix to the label (#2276)
  stdcall_decl sz =
        ptext (sLit "extern __attribute__((stdcall)) void ") <> pprCLabel lbl
        <> parens (commafy (replicate (sz `quot` wORD_SIZE) (machRep_U_CType wordWidth)))
        <> semi

type TEState = (UniqSet LocalReg, Map CLabel ())
newtype TE a = TE { unTE :: TEState -> (a, TEState) }

instance Monad TE where
   TE m >>= k  = TE $ \s -> case m s of (a, s') -> unTE (k a) s'
   return a    = TE $ \s -> (a, s)

te_lbl :: CLabel -> TE ()
te_lbl lbl = TE $ \(temps,lbls) -> ((), (temps, Map.insert lbl () lbls))

te_temp :: LocalReg -> TE ()
te_temp r = TE $ \(temps,lbls) -> ((), (addOneToUniqSet temps r, lbls))

runTE :: TE () -> TEState
runTE (TE m) = snd (m (emptyUniqSet, Map.empty))

te_Static :: CmmStatic -> TE ()
te_Static (CmmStaticLit lit) = te_Lit lit
te_Static _ = return ()

te_BB :: CmmBasicBlock -> TE ()
te_BB (BasicBlock _ ss)		= mapM_ te_Stmt ss

te_Lit :: CmmLit -> TE ()
te_Lit (CmmLabel l) = te_lbl l
te_Lit (CmmLabelOff l _) = te_lbl l
te_Lit (CmmLabelDiffOff l1 l2 _) = te_lbl l1
te_Lit _ = return ()

te_Stmt :: CmmStmt -> TE ()
te_Stmt (CmmAssign r e)		= te_Reg r >> te_Expr e
te_Stmt (CmmStore l r)		= te_Expr l >> te_Expr r
te_Stmt (CmmCall _ rs es _ _)	= mapM_ (te_temp.hintlessCmm) rs >>
				  mapM_ (te_Expr.hintlessCmm) es
te_Stmt (CmmCondBranch e _)	= te_Expr e
te_Stmt (CmmSwitch e _)		= te_Expr e
te_Stmt (CmmJump e _)		= te_Expr e
te_Stmt _			= return ()

te_Expr :: CmmExpr -> TE ()
te_Expr (CmmLit lit)		= te_Lit lit
te_Expr (CmmLoad e _)		= te_Expr e
te_Expr (CmmReg r)		= te_Reg r
te_Expr (CmmMachOp _ es) 	= mapM_ te_Expr es
te_Expr (CmmRegOff r _) 	= te_Reg r

te_Reg :: CmmReg -> TE ()
te_Reg (CmmLocal l) = te_temp l
te_Reg _            = return ()


-- ---------------------------------------------------------------------
-- C types for MachReps

cCast :: SDoc -> CmmExpr -> SDoc
cCast ty expr = parens ty <> pprExpr1 expr

cLoad :: CmmExpr -> CmmType -> SDoc
#ifdef BEWARE_LOAD_STORE_ALIGNMENT
cLoad expr rep =
    let decl = machRepCType rep <+> ptext (sLit "x") <> semi
        struct = ptext (sLit "struct") <+> braces (decl)
        packed_attr = ptext (sLit "__attribute__((packed))")
        cast = parens (struct <+> packed_attr <> char '*')
    in parens (cast <+> pprExpr1 expr) <> ptext (sLit "->x")
#else
cLoad expr rep = char '*' <> parens (cCast (machRepPtrCType rep) expr)
#endif

isCmmWordType :: CmmType -> Bool
-- True of GcPtrReg/NonGcReg of native word size
isCmmWordType ty = not (isFloatType ty) 
		   && typeWidth ty == wordWidth

-- This is for finding the types of foreign call arguments.  For a pointer
-- argument, we always cast the argument to (void *), to avoid warnings from
-- the C compiler.
machRepHintCType :: CmmType -> ForeignHint -> SDoc
machRepHintCType rep AddrHint    = ptext (sLit "void *")
machRepHintCType rep SignedHint = machRep_S_CType (typeWidth rep)
machRepHintCType rep _other     = machRepCType rep

machRepPtrCType :: CmmType -> SDoc
machRepPtrCType r | isCmmWordType r = ptext (sLit "P_")
	          | otherwise       = machRepCType r <> char '*'

machRepCType :: CmmType -> SDoc
machRepCType ty | isFloatType ty = machRep_F_CType w
		| otherwise	 = machRep_U_CType w
		where
		  w = typeWidth ty

machRep_F_CType :: Width -> SDoc
machRep_F_CType W32 = ptext (sLit "StgFloat") -- ToDo: correct?
machRep_F_CType W64 = ptext (sLit "StgDouble")
machRep_F_CType _   = panic "machRep_F_CType"

machRep_U_CType :: Width -> SDoc
machRep_U_CType w | w == wordWidth = ptext (sLit "W_")
machRep_U_CType W8  = ptext (sLit "StgWord8")
machRep_U_CType W16 = ptext (sLit "StgWord16")
machRep_U_CType W32 = ptext (sLit "StgWord32")
machRep_U_CType W64 = ptext (sLit "StgWord64")
machRep_U_CType _   = panic "machRep_U_CType"

machRep_S_CType :: Width -> SDoc
machRep_S_CType w | w == wordWidth = ptext (sLit "I_")
machRep_S_CType W8  = ptext (sLit "StgInt8")
machRep_S_CType W16 = ptext (sLit "StgInt16")
machRep_S_CType W32 = ptext (sLit "StgInt32")
machRep_S_CType W64 = ptext (sLit "StgInt64")
machRep_S_CType _   = panic "machRep_S_CType"
  

-- ---------------------------------------------------------------------
-- print strings as valid C strings

pprStringInCStyle :: [Word8] -> SDoc
pprStringInCStyle s = doubleQuotes (text (concatMap charToC s))

charToC :: Word8 -> String
charToC w = 
  case chr (fromIntegral w) of
	'\"' -> "\\\""
	'\'' -> "\\\'"
	'\\' -> "\\\\"
	c | c >= ' ' && c <= '~' -> [c]
          | otherwise -> ['\\',
                         chr (ord '0' + ord c `div` 64),
                         chr (ord '0' + ord c `div` 8 `mod` 8),
                         chr (ord '0' + ord c         `mod` 8)]

-- ---------------------------------------------------------------------------
-- Initialising static objects with floating-point numbers.  We can't
-- just emit the floating point number, because C will cast it to an int
-- by rounding it.  We want the actual bit-representation of the float.

-- This is a hack to turn the floating point numbers into ints that we
-- can safely initialise to static locations.

big_doubles 
  | widthInBytes W64 == 2 * wORD_SIZE  = True
  | widthInBytes W64 == wORD_SIZE      = False
  | otherwise = panic "big_doubles"

castFloatToIntArray :: STUArray s Int Float -> ST s (STUArray s Int Int)
castFloatToIntArray = castSTUArray

castDoubleToIntArray :: STUArray s Int Double -> ST s (STUArray s Int Int)
castDoubleToIntArray = castSTUArray

-- floats are always 1 word
floatToWord :: Rational -> CmmLit
floatToWord r
  = runST (do
	arr <- newArray_ ((0::Int),0)
	writeArray arr 0 (fromRational r)
	arr' <- castFloatToIntArray arr
	i <- readArray arr' 0
	return (CmmInt (toInteger i) wordWidth)
    )

doubleToWords :: Rational -> [CmmLit]
doubleToWords r
  | big_doubles				-- doubles are 2 words
  = runST (do
	arr <- newArray_ ((0::Int),1)
	writeArray arr 0 (fromRational r)
	arr' <- castDoubleToIntArray arr
	i1 <- readArray arr' 0
	i2 <- readArray arr' 1
	return [ CmmInt (toInteger i1) wordWidth
	       , CmmInt (toInteger i2) wordWidth
	       ]
    )
  | otherwise				-- doubles are 1 word
  = runST (do
	arr <- newArray_ ((0::Int),0)
	writeArray arr 0 (fromRational r)
	arr' <- castDoubleToIntArray arr
	i <- readArray arr' 0
	return [ CmmInt (toInteger i) wordWidth ]
    )

-- ---------------------------------------------------------------------------
-- Utils

wordShift :: Int
wordShift = widthInLog wordWidth

commafy :: [SDoc] -> SDoc
commafy xs = hsep $ punctuate comma xs

-- Print in C hex format: 0x13fa
pprHexVal :: Integer -> Width -> SDoc
pprHexVal 0 _ = ptext (sLit "0x0")
pprHexVal w rep
  | w < 0     = parens (char '-' <> ptext (sLit "0x") <> go (-w) <> repsuffix rep)
  | otherwise = ptext (sLit "0x") <> go w <> repsuffix rep
  where
  	-- type suffix for literals:
	-- Integer literals are unsigned in Cmm/C.  We explicitly cast to
	-- signed values for doing signed operations, but at all other
	-- times values are unsigned.  This also helps eliminate occasional
	-- warnings about integer overflow from gcc.

	-- on 32-bit platforms, add "ULL" to 64-bit literals
      repsuffix W64 | wORD_SIZE == 4 = ptext (sLit "ULL")
      	-- on 64-bit platforms with 32-bit int, add "L" to 64-bit literals
      repsuffix W64 | cINT_SIZE == 4 = ptext (sLit "UL")
      repsuffix _ = char 'U'
      
      go 0 = empty
      go w' = go q <> dig
           where
             (q,r) = w' `quotRem` 16
             dig | r < 10    = char (chr (fromInteger r + ord '0'))
                 | otherwise = char (chr (fromInteger r - 10 + ord 'a'))

