The @FamInst@ type: family instance heads

\begin{code}
module FamInst ( 
        checkFamInstConsistency, tcExtendLocalFamInstEnv, tcGetFamInstEnvs
    ) where

import HscTypes
import FamInstEnv
import TcMType
import TcRnMonad
import TyCon
import Name
import Module
import SrcLoc
import Outputable
import UniqFM
import FastString

import Maybes
import Control.Monad
import Data.Map (Map)
import qualified Data.Map as Map
\end{code}


%************************************************************************
%*									*
	Optimised overlap checking for family instances
%*									*
%************************************************************************

For any two family instance modules that we import directly or indirectly, we
check whether the instances in the two modules are consistent, *unless* we can
be certain that the instances of the two modules have already been checked for
consistency during the compilation of modules that we import.

Why do we need to check?  Consider 
   module X1 where	  	  module X2 where
    data T1			    data T2
    type instance F T1 b = Int	    type instance F a T2 = Char
    f1 :: F T1 a -> Int		    f2 :: Char -> F a T2
    f1 x = x			    f2 x = x

Now if we import both X1 and X2 we could make (f2 . f1) :: Int -> Char.
Notice that neither instance is an orphan.

How do we know which pairs of modules have already been checked?  Any pair of
modules where both modules occur in the `HscTypes.dep_finsts' set (of the
`HscTypes.Dependencies') of one of our directly imported modules must have
already been checked.  Everything else, we check now.  (So that we can be
certain that the modules in our `HscTypes.dep_finsts' are consistent.)

\begin{code}
-- The optimisation of overlap tests is based on determining pairs of modules
-- whose family instances need to be checked for consistency.
--
data ModulePair = ModulePair Module Module

-- canonical order of the components of a module pair
--
canon :: ModulePair -> (Module, Module)
canon (ModulePair m1 m2) | m1 < m2   = (m1, m2)
			 | otherwise = (m2, m1)

instance Eq ModulePair where
  mp1 == mp2 = canon mp1 == canon mp2

instance Ord ModulePair where
  mp1 `compare` mp2 = canon mp1 `compare` canon mp2

-- Sets of module pairs
--
type ModulePairSet = Map ModulePair ()

listToSet :: [ModulePair] -> ModulePairSet
listToSet l = Map.fromList (zip l (repeat ()))

checkFamInstConsistency :: [Module] -> [Module] -> TcM ()
checkFamInstConsistency famInstMods directlyImpMods
  = do { dflags     <- getDOpts
       ; (eps, hpt) <- getEpsAndHpt

       ; let { -- Fetch the iface of a given module.  Must succeed as
 	       -- all imported modules must already have been loaded.
	       modIface mod = 
	         case lookupIfaceByModule dflags hpt (eps_PIT eps) mod of
                   Nothing    -> panic "FamInst.checkFamInstConsistency"
                   Just iface -> iface

             ; hmiModule     = mi_module . hm_iface
	     ; hmiFamInstEnv = mkFamInstEnv . md_fam_insts . hm_details
	     ; mkFamInstEnv  = extendFamInstEnvList emptyFamInstEnv
             ; hptModInsts   = [ (hmiModule hmi, hmiFamInstEnv hmi) 
			       | hmi <- eltsUFM hpt]
             ; modInstsEnv   = eps_mod_fam_inst_env eps	-- external modules
			       `extendModuleEnvList`	-- plus
			       hptModInsts		-- home package modules
	     ; groups        = map (dep_finsts . mi_deps . modIface) 
				   directlyImpMods
	     ; okPairs       = listToSet $ concatMap allPairs groups
	         -- instances of okPairs are consistent
	     ; criticalPairs = listToSet $ allPairs famInstMods
	         -- all pairs that we need to consider
             ; toCheckPairs  = Map.keys $ criticalPairs `Map.difference` okPairs
	         -- the difference gives us the pairs we need to check now
	     }

       ; mapM_ (check modInstsEnv) toCheckPairs
       }
  where
    allPairs []     = []
    allPairs (m:ms) = map (ModulePair m) ms ++ allPairs ms

    -- The modules are guaranteed to be in the environment, as they are either
    -- already loaded in the EPS or they are in the HPT.
    --
    check modInstsEnv (ModulePair m1 m2)
      = let { instEnv1 = (expectJust "checkFamInstConsistency") . lookupModuleEnv modInstsEnv $ m1
	    ; instEnv2 = (expectJust "checkFamInstConsistency") . lookupModuleEnv modInstsEnv $ m2
	    ; insts1   = famInstEnvElts instEnv1
	    }
        in
	mapM_ (checkForConflicts (emptyFamInstEnv, instEnv2)) insts1
\end{code}

%************************************************************************
%*									*
	Extending the family instance environment
%*									*
%************************************************************************

\begin{code}
-- Add new locally-defined family instances
tcExtendLocalFamInstEnv :: [FamInst] -> TcM a -> TcM a
tcExtendLocalFamInstEnv fam_insts thing_inside
 = do { env <- getGblEnv
      ; inst_env' <- foldlM addLocalFamInst (tcg_fam_inst_env env) fam_insts
      ; let env' = env { tcg_fam_insts    = fam_insts ++ tcg_fam_insts env,
			 tcg_fam_inst_env = inst_env' }
      ; setGblEnv env' thing_inside 
      }

-- Check that the proposed new instance is OK, 
-- and then add it to the home inst env
addLocalFamInst :: FamInstEnv -> FamInst -> TcM FamInstEnv
addLocalFamInst home_fie famInst
  = do {       -- Load imported instances, so that we report
	       -- overlaps correctly
       ; eps <- getEps
       ; let inst_envs = (eps_fam_inst_env eps, home_fie)

	       -- Check for conflicting instance decls
       ; checkForConflicts inst_envs famInst

	       -- OK, now extend the envt
       ; return (extendFamInstEnv home_fie famInst) 
       }
\end{code}

%************************************************************************
%*									*
	Checking an instance against conflicts with an instance env
%*									*
%************************************************************************

Check whether a single family instance conflicts with those in two instance
environments (one for the EPS and one for the HPT).

\begin{code}
checkForConflicts :: (FamInstEnv, FamInstEnv) -> FamInst -> TcM ()
checkForConflicts inst_envs famInst
  = do { 	-- To instantiate the family instance type, extend the instance
		-- envt with completely fresh template variables
		-- This is important because the template variables must
		-- not overlap with anything in the things being looked up
		-- (since we do unification).  
		-- We use tcInstSkolType because we don't want to allocate
		-- fresh *meta* type variables.  

       ; skol_tvs <- tcInstSkolTyVars (tyConTyVars (famInstTyCon famInst))
       ; let conflicts = lookupFamInstEnvConflicts inst_envs famInst skol_tvs
       ; unless (null conflicts) $
	   conflictInstErr famInst (fst (head conflicts))
       }
  where

conflictInstErr :: FamInst -> FamInst -> TcRn ()
conflictInstErr famInst conflictingFamInst
  = addFamInstLoc famInst $
    addErr (hang (ptext (sLit "Conflicting family instance declarations:"))
	       2 (pprFamInsts [famInst, conflictingFamInst]))

addFamInstLoc :: FamInst -> TcRn a -> TcRn a
addFamInstLoc famInst thing_inside
  = setSrcSpan (mkSrcSpan loc loc) thing_inside
  where
    loc = getSrcLoc famInst
\end{code} 

\begin{code} 

tcGetFamInstEnvs :: TcM (FamInstEnv, FamInstEnv)
-- Gets both the external-package inst-env
-- and the home-pkg inst env (includes module being compiled)
tcGetFamInstEnvs 
  = do { eps <- getEps; env <- getGblEnv
       ; return (eps_fam_inst_env eps, tcg_fam_inst_env env) 
       }


\end{code}
