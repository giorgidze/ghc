%
% (c) The GRASP/AQUA Project, Glasgow University, 1993-1998
%

\section[MkIface]{Print an interface for a module}

\begin{code}
module MkIface ( 
	showIface, mkFinalIface,
	pprModDetails, pprIface, pprUsage, pprUsages, pprExports,
	ifaceTyThing,
  ) where

#include "HsVersions.h"

import HsSyn
import HsCore		( HsIdInfo(..), UfExpr(..), toUfExpr, toUfBndr )
import HsTypes		( toHsTyVars )
import TysPrim		( alphaTyVars )
import BasicTypes	( NewOrData(..), Activation(..),
			  Version, initialVersion, bumpVersion 
			)
import NewDemand	( isTopSig )
import RnMonad
import RnHsSyn		( RenamedInstDecl, RenamedTyClDecl )
import HscTypes		( VersionInfo(..), ModIface(..), ModDetails(..),
			  ModuleLocation(..), GhciMode(..), 
			  FixityEnv, lookupFixity, collectFixities,
			  IfaceDecls, mkIfaceDecls, dcl_tycl, dcl_rules, dcl_insts,
			  TyThing(..), DFunId, TypeEnv,
			  GenAvailInfo,
			  WhatsImported(..), GenAvailInfo(..), 
			  ImportVersion, Deprecations(..),
			  lookupVersion, typeEnvIds
			)

import CmdLineOpts
import Id		( idType, idInfo, isImplicitId, idCgInfo,
			  isLocalId, idName,
			)
import DataCon		( dataConId, dataConSig, dataConFieldLabels, dataConStrictMarks )
import IdInfo		-- Lots
import Var              ( Var )
import CoreSyn		( CoreRule(..), IdCoreRule )
import CoreFVs		( ruleLhsFreeNames )
import CoreUnfold	( neverUnfold, unfoldingTemplate )
import PprCore		( pprIdRules )
import Name		( getName, toRdrName, isExternalName, 
			  nameIsLocalOrFrom, Name, NamedThing(..) )
import NameEnv
import NameSet
import OccName		( pprOccName )
import TyCon
import Class		( classExtraBigSig, classTyCon, DefMeth(..) )
import FieldLabel	( fieldLabelType )
import TcType		( tcSplitSigmaTy, tidyTopType, deNoteType, namesOfDFunHead )
import SrcLoc		( noSrcLoc )
import Outputable
import Module		( ModuleName )
import Util		( sortLt, dropList )
import Binary		( getBinFileWithDict )
import BinIface		( writeBinIface )
import ErrUtils		( dumpIfSet_dyn )

import Monad		( when )
import Maybe		( catMaybes )
import IO		( putStrLn )
\end{code}


%************************************************************************
%*				 					*
\subsection{Print out the contents of a binary interface}
%*				 					*
%************************************************************************

\begin{code}
showIface :: FilePath -> IO ()
showIface filename = do
   parsed_iface <- Binary.getBinFileWithDict filename
   let ParsedIface{
      pi_mod=pi_mod, pi_pkg=pi_pkg, pi_vers=pi_vers,
      pi_orphan=pi_orphan, pi_usages=pi_usages,
      pi_exports=pi_exports, pi_decls=pi_decls,
      pi_fixity=pi_fixity, pi_insts=pi_insts,
      pi_rules=pi_rules, pi_deprecs=pi_deprecs } = parsed_iface
   putStrLn (showSDoc (vcat [
	text "__interface" <+> doubleQuotes (ppr pi_pkg)
	   <+> ppr pi_mod <+> ppr pi_vers 
	   <+> (if pi_orphan then char '!' else empty)
	   <+> ptext SLIT("where"),
	-- no instance Outputable (WhatsImported):
	pprExports id (snd pi_exports),
	pprUsages  id pi_usages,
	hsep (map ppr_fix pi_fixity) <> semi,
	vcat (map ppr_inst pi_insts),
	vcat (map ppr_decl pi_decls),
	ppr pi_rules
	-- no instance Outputable (Either):
	-- ppr pi_deprecs
	]))
   where
    ppr_fix (n,f) = ppr f <+> ppr n
    ppr_inst i  = ppr i <+> semi
    ppr_decl (v,d)  = int v <+> ppr d <> semi
\end{code}

%************************************************************************
%*				 					*
\subsection{Completing an interface}
%*				 					*
%************************************************************************

\begin{code}



mkFinalIface :: GhciMode
	     -> DynFlags
	     -> ModuleLocation
	     -> Maybe ModIface		-- The old interface, if we have it
	     -> ModIface		-- The new one, minus the decls and versions
	     -> ModDetails		-- The ModDetails for this module
	     -> IO ModIface		-- The new one, complete with decls and versions
-- mkFinalIface 
--	a) completes the interface
--	b) writes it out to a file if necessary

mkFinalIface ghci_mode dflags location maybe_old_iface 
	new_iface@ModIface{ mi_module=mod }
	new_details@ModDetails{ md_insts=insts, 
				md_rules=rules,
				md_types=types }
  = do	{ 
		-- Add the new declarations, and the is-orphan flag
	  let iface_w_decls = new_iface { mi_decls = new_decls,
					  mi_orphan = orphan_mod }

		-- Add version information
	; let (final_iface, maybe_diffs) = _scc_ "versioninfo" addVersionInfo maybe_old_iface iface_w_decls

		-- Write the interface file, if necessary
	; when (must_write_hi_file maybe_diffs)
		(writeBinIface hi_file_path final_iface)
--		(writeIface hi_file_path final_iface)

		-- Debug printing
	; write_diffs dflags final_iface maybe_diffs

	; orphan_mod `seq`
	  return final_iface }

  where
     must_write_hi_file Nothing       = False
     must_write_hi_file (Just _diffs) = ghci_mode /= Interactive
		-- We must write a new .hi file if there are some changes
		-- and we're not in interactive mode
		-- maybe_diffs = 'Nothing' means that even the usages havn't changed, 
		--     so there's no need to write a new interface file.  But even if 
		--     the usages have changed, the module version may not have.

     hi_file_path = ml_hi_file location
     new_decls    = mkIfaceDecls ty_cls_dcls rule_dcls inst_dcls
     inst_dcls    = map ifaceInstance insts
     ty_cls_dcls  = foldNameEnv ifaceTyThing_acc [] types
     rule_dcls    = map ifaceRule rules
     orphan_mod   = isOrphanModule mod new_details

write_diffs :: DynFlags -> ModIface -> Maybe SDoc -> IO ()
write_diffs dflags new_iface Nothing
  = do when (dopt Opt_D_dump_hi_diffs dflags) (printDump (text "INTERFACE UNCHANGED"))
       dumpIfSet_dyn dflags Opt_D_dump_hi "UNCHANGED FINAL INTERFACE" (pprIface new_iface)

write_diffs dflags new_iface (Just sdoc_diffs)
  = do dumpIfSet_dyn dflags Opt_D_dump_hi_diffs "INTERFACE HAS CHANGED" sdoc_diffs
       dumpIfSet_dyn dflags Opt_D_dump_hi "NEW FINAL INTERFACE" (pprIface new_iface)
\end{code}

\begin{code}
isOrphanModule :: Module -> ModDetails -> Bool
isOrphanModule this_mod (ModDetails {md_insts = insts, md_rules = rules})
  = any orphan_inst insts || any orphan_rule rules
  where
	-- A rule is an orphan if the LHS mentions nothing defined locally
    orphan_inst dfun_id = no_locals (namesOfDFunHead (idType dfun_id))
	-- A instance is an orphan if its head mentions nothing defined locally
    orphan_rule rule    = no_locals (ruleLhsFreeNames rule)

    no_locals names     = isEmptyNameSet (filterNameSet (nameIsLocalOrFrom this_mod) names)
\end{code}

Implicit Ids and class tycons aren't included in interface files, so
we miss them out of the accumulating parameter here.

\begin{code}
ifaceTyThing_acc :: TyThing -> [RenamedTyClDecl] -> [RenamedTyClDecl]
ifaceTyThing_acc (AnId   id) so_far | isImplicitId id = so_far
ifaceTyThing_acc (ATyCon id) so_far | isClassTyCon id = so_far
ifaceTyThing_acc other so_far = ifaceTyThing other : so_far
\end{code}

Convert *any* TyThing into a RenamedTyClDecl.  Used both for
generating interface files and for the ':info' command in GHCi.

\begin{code}
ifaceTyThing :: TyThing -> RenamedTyClDecl
ifaceTyThing (AClass clas) = cls_decl
  where
    cls_decl = ClassDecl { tcdCtxt	= toHsContext sc_theta,
			   tcdName	= getName clas,
			   tcdTyVars	= toHsTyVars clas_tyvars,
			   tcdFDs 	= toHsFDs clas_fds,
			   tcdSigs	= map toClassOpSig op_stuff,
			   tcdMeths	= Nothing, 
			   tcdSysNames  = sys_names,
			   tcdLoc	= noSrcLoc }

    (clas_tyvars, clas_fds, sc_theta, sc_sels, op_stuff) = classExtraBigSig clas
    tycon     = classTyCon clas
    data_con  = head (tyConDataCons tycon)
    sys_names = mkClassDeclSysNames (getName tycon, getName data_con, 
				     getName (dataConId data_con), map getName sc_sels)

    toClassOpSig (sel_id, def_meth)
	= ASSERT(sel_tyvars == clas_tyvars)
	  ClassOpSig (getName sel_id) def_meth' (toHsType op_ty) noSrcLoc
	where
	  (sel_tyvars, _, op_ty) = tcSplitSigmaTy (idType sel_id)
	  def_meth' = case def_meth of
			 NoDefMeth  -> NoDefMeth
			 GenDefMeth -> GenDefMeth
			 DefMeth id -> DefMeth (getName id)

ifaceTyThing (ATyCon tycon) = ty_decl
  where
    ty_decl | isSynTyCon tycon
	    = TySynonym { tcdName   = getName tycon,
		 	  tcdTyVars = toHsTyVars tyvars,
			  tcdSynRhs = toHsType syn_ty,
			  tcdLoc    = noSrcLoc }

	    | isAlgTyCon tycon
	    = TyData {	tcdND	  = new_or_data,
			tcdCtxt   = toHsContext (tyConTheta tycon),
			tcdName   = getName tycon,
		 	tcdTyVars = toHsTyVars tyvars,
			tcdCons   = ifaceConDecls (tyConDataConDetails tycon),
			tcdDerivs = Nothing,
		        tcdSysNames  = map getName (tyConGenIds tycon),
			tcdLoc	     = noSrcLoc }

	    | isForeignTyCon tycon
	    = ForeignType { tcdName    = getName tycon,
	    		    tcdExtName = Nothing,
			    tcdFoType  = DNType,	-- The only case at present
			    tcdLoc     = noSrcLoc }

	    | isPrimTyCon tycon || isFunTyCon tycon
		-- needed in GHCi for ':info Int#', for example
	    = TyData {  tcdND     = DataType,
			tcdCtxt   = [],
			tcdName   = getName tycon,
		 	tcdTyVars = toHsTyVars (take (tyConArity tycon) alphaTyVars),
			tcdCons   = Unknown,
			tcdDerivs = Nothing,
		        tcdSysNames  = [],
			tcdLoc	     = noSrcLoc }

	    | otherwise = pprPanic "ifaceTyThing" (ppr tycon)

    tyvars      = tyConTyVars tycon
    (_, syn_ty) = getSynTyConDefn tycon
    new_or_data | isNewTyCon tycon = NewType
	        | otherwise	   = DataType

    ifaceConDecls Unknown       = Unknown
    ifaceConDecls (HasCons n)   = HasCons n
    ifaceConDecls (DataCons cs) = DataCons (map ifaceConDecl cs)

    ifaceConDecl data_con 
	= ConDecl (getName data_con) (getName (dataConId data_con))
		  (toHsTyVars ex_tyvars)
		  (toHsContext ex_theta)
		  details noSrcLoc
	where
	  (tyvars1, _, ex_tyvars, ex_theta, arg_tys, tycon1) = dataConSig data_con
          field_labels   = dataConFieldLabels data_con
          strict_marks   = dropList ex_theta (dataConStrictMarks data_con)
				-- The 'drop' is because dataConStrictMarks
				-- includes the existential dictionaries
	  details | null field_labels
	    	  = ASSERT( tycon == tycon1 && tyvars == tyvars1 )
	    	    VanillaCon (zipWith BangType strict_marks (map toHsType arg_tys))

    	    	  | otherwise
	    	  = RecCon (zipWith mk_field strict_marks field_labels)

    mk_field strict_mark field_label
	= ([getName field_label], BangType strict_mark (toHsType (fieldLabelType field_label)))

ifaceTyThing (AnId id) = iface_sig
  where
    iface_sig = IfaceSig { tcdName   = getName id, 
			   tcdType   = toHsType id_type,
			   tcdIdInfo = hs_idinfo,
			   tcdLoc    =  noSrcLoc }

    id_type = idType id
    id_info = idInfo id
    cg_info = idCgInfo id
    arity_info = arityInfo id_info
    caf_info   = cgCafInfo cg_info

    hs_idinfo | opt_OmitInterfacePragmas
	      = []
 	      | otherwise
  	      = catMaybes [arity_hsinfo,  caf_hsinfo,
			   strict_hsinfo, wrkr_hsinfo,
			   unfold_hsinfo] 

    ------------  Arity  --------------
    arity_hsinfo | arity_info == 0 = Nothing
		 | otherwise       = Just (HsArity arity_info)

    ------------ Caf Info --------------
    caf_hsinfo = case caf_info of
		   NoCafRefs -> Just HsNoCafRefs
		   _other    -> Nothing

    ------------  Strictness  --------------
	-- No point in explicitly exporting TopSig
    strict_hsinfo = case newStrictnessInfo id_info of
			Just sig | not (isTopSig sig) -> Just (HsStrictness sig)
			_other			      -> Nothing

    ------------  Worker  --------------
    work_info   = workerInfo id_info
    has_worker  = case work_info of { HasWorker _ _ -> True; other -> False }
    wrkr_hsinfo = case work_info of
		    HasWorker work_id wrap_arity -> 
			Just (HsWorker (getName work_id) wrap_arity)
		    NoWorker -> Nothing

    ------------  Unfolding  --------------
	-- The unfolding is redundant if there is a worker
    unfold_info = unfoldingInfo id_info
    inline_prag = inlinePragInfo id_info
    rhs		= unfoldingTemplate unfold_info
    unfold_hsinfo |  neverUnfold unfold_info 
		  || has_worker = Nothing
		  | otherwise	= Just (HsUnfold inline_prag (toUfExpr rhs))
\end{code}

\begin{code}
ifaceInstance :: DFunId -> RenamedInstDecl
ifaceInstance dfun_id
  = InstDecl (toHsType tidy_ty) EmptyMonoBinds [] (Just (getName dfun_id)) noSrcLoc			 
  where
    tidy_ty = tidyTopType (deNoteType (idType dfun_id))
		-- The deNoteType is very important.   It removes all type
		-- synonyms from the instance type in interface files.
		-- That in turn makes sure that when reading in instance decls
		-- from interface files that the 'gating' mechanism works properly.
		-- Otherwise you could have
		--	type Tibble = T Int
		--	instance Foo Tibble where ...
		-- and this instance decl wouldn't get imported into a module
		-- that mentioned T but not Tibble.

ifaceRule :: IdCoreRule -> RuleDecl Name pat
ifaceRule (id, BuiltinRule _ _)
  = pprTrace "toHsRule: builtin" (ppr id) (bogusIfaceRule id)

ifaceRule (id, Rule name act bndrs args rhs)
  = IfaceRule name act (map toUfBndr bndrs) (getName id)
	      (map toUfExpr args) (toUfExpr rhs) noSrcLoc

bogusIfaceRule :: (NamedThing a) => a -> RuleDecl Name pat
bogusIfaceRule id
  = IfaceRule SLIT("bogus") NeverActive [] (getName id) [] (UfVar (getName id)) noSrcLoc
\end{code}


%************************************************************************
%*				 					*
\subsection{Checking if the new interface is up to date
%*				 					*
%************************************************************************

\begin{code}
addVersionInfo :: Maybe ModIface		-- The old interface, read from M.hi
	       -> ModIface			-- The new interface decls
	       -> (ModIface, Maybe SDoc)	-- Nothing => no change; no need to write new Iface
						-- Just mi => Here is the new interface to write
						-- 	      with correct version numbers

-- NB: the fixities, declarations, rules are all assumed
-- to be sorted by increasing order of hsDeclName, so that 
-- we can compare for equality

addVersionInfo Nothing new_iface
-- No old interface, so definitely write a new one!
  = (new_iface, Just (text "No old interface available"))

addVersionInfo (Just old_iface@(ModIface { mi_version  = old_version, 
				       	   mi_decls    = old_decls,
				       	   mi_fixities = old_fixities,
					   mi_deprecs  = old_deprecs }))
	       new_iface@(ModIface { mi_decls    = new_decls,
				     mi_fixities = new_fixities,
				     mi_deprecs  = new_deprecs })

  | no_output_change && no_usage_change
  = (new_iface, Nothing)
	-- don't return the old iface because it may not have an
	-- mi_globals field set to anything reasonable.

  | otherwise		-- Add updated version numbers
  = --pprTrace "completeIface" (ppr (dcl_tycl old_decls))
    (final_iface, Just pp_diffs)
	
  where
    final_iface = new_iface { mi_version = new_version }
    old_mod_vers = vers_module  old_version
    new_version = VersionInfo { vers_module  = bumpVersion no_output_change old_mod_vers,
				vers_exports = bumpVersion no_export_change (vers_exports old_version),
				vers_rules   = bumpVersion no_rule_change   (vers_rules   old_version),
				vers_decls   = tc_vers }

    no_output_change = no_tc_change && no_rule_change && no_export_change && no_deprec_change
    no_usage_change  = mi_usages old_iface == mi_usages new_iface

    no_export_change = mi_exports old_iface == mi_exports new_iface		-- Kept sorted
    no_rule_change   = dcl_rules old_decls  == dcl_rules  new_decls		-- Ditto
    no_deprec_change = old_deprecs	    == new_deprecs

	-- Fill in the version number on the new declarations by looking at the old declarations.
	-- Set the flag if anything changes. 
	-- Assumes that the decls are sorted by hsDeclName.
    (no_tc_change,  pp_tc_diffs,  tc_vers) = diffDecls old_version old_fixities new_fixities
						       (dcl_tycl old_decls) (dcl_tycl new_decls)
    pp_diffs = vcat [pp_tc_diffs,
		     pp_change no_export_change "Export list",
		     pp_change no_rule_change   "Rules",
		     pp_change no_deprec_change "Deprecations",
		     pp_change no_usage_change  "Usages"]
    pp_change True  what = empty
    pp_change False what = text what <+> ptext SLIT("changed")

diffDecls :: VersionInfo				-- Old version
	  -> FixityEnv -> FixityEnv			-- Old and new fixities
	  -> [RenamedTyClDecl] -> [RenamedTyClDecl]	-- Old and new decls
	  -> (Bool,		-- True <=> no change
	      SDoc,		-- Record of differences
	      NameEnv Version)	-- New version map

diffDecls (VersionInfo { vers_module = old_mod_vers, vers_decls = old_decls_vers })
	  old_fixities new_fixities old new
  = diff True empty emptyNameEnv old new
  where
	-- When seeing if two decls are the same, 
	-- remember to check whether any relevant fixity has changed
    eq_tc  d1 d2 = d1 == d2 && all (same_fixity . fst) (tyClDeclNames d1)
    same_fixity n = lookupFixity old_fixities n == lookupFixity new_fixities n

    diff ok_so_far pp new_vers []  []      = (ok_so_far, pp, new_vers)
    diff ok_so_far pp new_vers (od:ods) [] = diff False (pp $$ only_old od) new_vers	      ods []
    diff ok_so_far pp new_vers [] (nd:nds) = diff False (pp $$ only_new nd) new_vers_with_new []  nds
	where
	  new_vers_with_new = extendNameEnv new_vers (tyClDeclName nd) (bumpVersion False old_mod_vers)
		-- When adding a new item, start from the old module version
		-- This way, if you have version 4 of f, then delete f, then add f again,
		-- you'll get version 6 of f, which will (correctly) force recompilation of
		-- clients

    diff ok_so_far pp new_vers (od:ods) (nd:nds)
	= case od_name `compare` nd_name of
		LT -> diff False (pp $$ only_old od) new_vers ods      (nd:nds)
		GT -> diff False (pp $$ only_new nd) new_vers (od:ods) nds
		EQ | od `eq_tc` nd -> diff ok_so_far pp 		   new_vers	      ods nds
		   | otherwise     -> diff False     (pp $$ changed od nd) new_vers_with_diff ods nds
	where
 	  od_name = tyClDeclName od
 	  nd_name = tyClDeclName nd
	  new_vers_with_diff = extendNameEnv new_vers nd_name (bumpVersion False old_version)
	  old_version = lookupVersion old_decls_vers od_name

    only_old d    = ptext SLIT("Only in old iface:") <+> ppr d
    only_new d    = ptext SLIT("Only in new iface:") <+> ppr d
    changed od nd = ptext SLIT("Changed in iface: ") <+> ((ptext SLIT("Old:") <+> ppr od) $$ 
							 (ptext SLIT("New:")  <+> ppr nd))
\end{code}



%************************************************************************
%*				 					*
\subsection{Writing ModDetails}
%*				 					*
%************************************************************************

\begin{code}
pprModDetails :: ModDetails -> SDoc
pprModDetails (ModDetails { md_types = type_env, md_insts = dfun_ids, md_rules = rules })
  = vcat [ dump_types dfun_ids type_env
	 , dump_insts dfun_ids
	 , dump_rules rules]
	  
dump_types :: [Var] -> TypeEnv -> SDoc
dump_types dfun_ids type_env
  = text "TYPE SIGNATURES" $$ nest 4 (dump_sigs ids)
  where
    ids = [id | id <- typeEnvIds type_env, want_sig id]
    want_sig id | opt_PprStyle_Debug = True
	        | otherwise	     = isLocalId id && 
				       isExternalName (idName id) && 
				       not (id `elem` dfun_ids)
	-- isLocalId ignores data constructors, records selectors etc
	-- The isExternalName ignores local dictionary and method bindings
	-- that the type checker has invented.  User-defined things have
	-- Global names.

dump_insts :: [Var] -> SDoc
dump_insts []       = empty
dump_insts dfun_ids = text "INSTANCES" $$ nest 4 (dump_sigs dfun_ids)

dump_sigs :: [Var] -> SDoc
dump_sigs ids
	-- Print type signatures
   	-- Convert to HsType so that we get source-language style printing
	-- And sort by RdrName
  = vcat $ map ppr_sig $ sortLt lt_sig $
    [ (toRdrName id, toHsType (idType id))
    | id <- ids ]
  where
    lt_sig (n1,_) (n2,_) = n1 < n2
    ppr_sig (n,t)        = ppr n <+> dcolon <+> ppr t

dump_rules :: [IdCoreRule] -> SDoc
dump_rules [] = empty
dump_rules rs = vcat [ptext SLIT("{-# RULES"),
		      nest 4 (pprIdRules rs),
		      ptext SLIT("#-}")]
\end{code}


%************************************************************************
%*				 					*
\subsection{Writing an interface file}
%*				 					*
%************************************************************************

\begin{code}
pprIface :: ModIface -> SDoc
pprIface iface
 = vcat [ ptext SLIT("__interface")
		<+> doubleQuotes (ptext (mi_package iface))
		<+> ppr (mi_module iface) <+> ppr (vers_module version_info)
		<+> pp_sub_vers
		<+> (if mi_orphan iface then char '!' else empty)
		<+> int opt_HiVersion
		<+> ptext SLIT("where")

	, pprExports nameOccName (mi_exports iface)
	, pprUsages  nameOccName (mi_usages iface)

	, pprFixities (mi_fixities iface) (dcl_tycl decls)
	, pprIfaceDecls (vers_decls version_info) decls
	, pprRulesAndDeprecs (dcl_rules decls) (mi_deprecs iface)
	]
  where
    version_info = mi_version iface
    decls	 = mi_decls iface
    exp_vers     = vers_exports version_info

    rule_vers	 = vers_rules version_info

    pp_sub_vers | exp_vers == initialVersion && rule_vers == initialVersion = empty
		| otherwise = brackets (ppr exp_vers <+> ppr rule_vers)
\end{code}

When printing export lists, we print like this:
	Avail   f		f
	AvailTC C [C, x, y]	C(x,y)
	AvailTC C [x, y]	C!(x,y)		-- Exporting x, y but not C

\begin{code}
pprExports :: Eq a => (a -> OccName) -> [(ModuleName, [GenAvailInfo a])] -> SDoc
pprExports getOcc exports = vcat (map (pprExport getOcc) exports)

pprExport :: Eq a => (a -> OccName) -> (ModuleName, [GenAvailInfo a]) -> SDoc
pprExport getOcc (mod, items)
 = hsep [ ptext SLIT("__export "), ppr mod, hsep (map pp_avail items) ] <> semi
  where
    --pp_avail :: GenAvailInfo a -> SDoc
    pp_avail (Avail name)    		     = ppr (getOcc name)
    pp_avail (AvailTC _ [])		     = empty
    pp_avail (AvailTC n (n':ns)) 
	| n==n'     = ppr (getOcc n) <> pp_export ns
 	| otherwise = ppr (getOcc n) <> char '|' <> pp_export (n':ns)
    
    pp_export []    = empty
    pp_export names = braces (hsep (map (ppr.getOcc) names))

pprOcc :: Name -> SDoc	-- Print the occurrence name only
pprOcc n = pprOccName (nameOccName n)
\end{code}


\begin{code}
pprUsages :: (a -> OccName) -> [ImportVersion a] -> SDoc
pprUsages getOcc usages = vcat (map (pprUsage getOcc) usages)

pprUsage :: (a -> OccName) -> ImportVersion a -> SDoc
pprUsage getOcc (m, has_orphans, is_boot, whats_imported)
  = hsep [ptext SLIT("import"), ppr m, 
	  pp_orphan, pp_boot,
	  pp_versions whats_imported
    ] <> semi
  where
    pp_orphan | has_orphans = char '!'
	      | otherwise   = empty
    pp_boot   | is_boot     = char '@'
              | otherwise   = empty

	-- Importing the whole module is indicated by an empty list
    pp_versions NothingAtAll   		    = empty
    pp_versions (Everything v) 		    = dcolon <+> int v
    pp_versions (Specifically vm ve nvs vr) = 
	dcolon <+> int vm <+> pp_export_version ve <+> int vr 
	<+> hsep [ ppr (getOcc n) <+> int v | (n,v) <- nvs ]

    pp_export_version Nothing  = empty
    pp_export_version (Just v) = int v
\end{code}

\begin{code}
pprIfaceDecls :: NameEnv Int -> IfaceDecls -> SDoc
pprIfaceDecls version_map decls
  = vcat [ vcat [ppr i <+> semi | i <- dcl_insts decls]
	 , vcat (map ppr_decl (dcl_tycl decls))
	 ]
  where
    ppr_decl d  = ppr_vers d <+> ppr d <> semi

	-- Print the version for the decl
    ppr_vers d = case lookupNameEnv version_map (tyClDeclName d) of
		   Nothing -> empty
		   Just v  -> int v
\end{code}

\begin{code}
pprFixities :: NameEnv Fixity
	    -> [TyClDecl Name pat]
	    -> SDoc
pprFixities fixity_map decls
  = hsep [ ppr fix <+> ppr n 
	 | (n,fix) <- collectFixities fixity_map decls ] <> semi

-- Disgusting to print these two together, but that's 
-- the way the interface parser currently expects them.
pprRulesAndDeprecs :: (Outputable a) => [a] -> Deprecations -> SDoc
pprRulesAndDeprecs [] NoDeprecs = empty
pprRulesAndDeprecs rules deprecs
  = ptext SLIT("{-##") <+> (pp_rules rules $$ pp_deprecs deprecs) <+> ptext SLIT("##-}")
  where
    pp_rules []    = empty
    pp_rules rules = ptext SLIT("__R") <+> vcat (map ppr rules)

    pp_deprecs NoDeprecs = empty
    pp_deprecs deprecs   = ptext SLIT("__D") <+> guts
			  where
			    guts = case deprecs of
					DeprecAll txt  -> doubleQuotes (ptext txt)
					DeprecSome env -> ppr_deprec_env env

ppr_deprec_env :: NameEnv (Name, FAST_STRING) -> SDoc
ppr_deprec_env env = vcat (punctuate semi (map pp_deprec (nameEnvElts env)))
	           where
   	 	     pp_deprec (name, txt) = pprOcc name <+> doubleQuotes (ptext txt)
\end{code}
