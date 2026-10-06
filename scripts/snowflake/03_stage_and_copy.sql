-- ============================================================
-- SCRIPT 03 — Stage interne et COPY INTO
-- ============================================================
-- Approche production : les CSV générés par le script Python sont
-- uploadés vers un stage interne Snowflake, puis chargés en bulk
-- avec COPY INTO (parallélisation native, gestion des erreurs).
--
-- Instructions :
--   1. Générer les données : python scripts/python/generate_data.py --scale M
--   2. Exécuter la partie STAGE + FILE FORMAT ci-dessous
--   3. Uploader les fichiers via SnowSQL :
--        PUT file://data/raw/*.csv.gz @FINTRACK_STAGE AUTO_COMPRESS=FALSE;
--   4. Exécuter les COPY INTO
-- ============================================================

USE ROLE FINTRACK_INGESTION_ROLE;
USE WAREHOUSE WH_INGESTION;
USE DATABASE FINTRACK_PROD;
USE SCHEMA RAW;

ALTER SESSION SET QUERY_TAG = 'stage_and_copy|fintrack_perf_scale';

-- ============================================
-- FILE FORMAT réutilisable
-- ============================================
CREATE OR REPLACE FILE FORMAT ff_csv_gz
    TYPE = CSV
    COMPRESSION = GZIP
    FIELD_DELIMITER = ','
    RECORD_DELIMITER = '\n'
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('', 'NULL', 'null')
    EMPTY_FIELD_AS_NULL = TRUE
    ENCODING = 'UTF-8'
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
    TRIM_SPACE = TRUE;

-- ============================================
-- STAGE INTERNE
-- ============================================
CREATE OR REPLACE STAGE fintrack_stage
    FILE_FORMAT = ff_csv_gz
    COMMENT = 'Stage interne pour les CSV générés par le script Python';

-- ============================================
-- COPY INTO — commandes à exécuter APRÈS le PUT
-- ============================================

-- IMPORTANT : chaque COPY INTO liste explicitement les colonnes cibles
-- (dans l'ordre exact du CSV généré), en excluant _loaded_at. Un COPY INTO
-- sans liste de colonnes mappe positionnellement le CSV sur TOUTES les
-- colonnes de la table dans l'ordre du DDL ; comme _loaded_at est la
-- dernière colonne de chaque table et n'existe pas dans le CSV, elle se
-- retrouvait chargée à NULL au lieu de déclencher son DEFAULT
-- CURRENT_TIMESTAMP() — cassant silencieusement toute la logique
-- incrémentale (is_incremental() des modèles staging/marts) qui filtre sur
-- _loaded_at.

-- Tenants (petit fichier)
COPY INTO raw_tenants (
    tenant_id, tenant_code, tenant_name, country_code, devise_locale,
    date_onboarding, sla_freshness_hours, contract_tier, is_active
)
FROM @fintrack_stage/raw_tenants.csv.gz
FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
ON_ERROR = 'ABORT_STATEMENT';

-- Catégories
COPY INTO raw_categories (
    categorie_id, nom_categorie, type_categorie, groupe,
    categorie_parent_id, niveau_hierarchique, is_active, date_creation
)
FROM @fintrack_stage/raw_categories.csv.gz
FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
ON_ERROR = 'ABORT_STATEMENT';

-- FX rates
COPY INTO raw_fx_rates (
    fx_id, devise_source, devise_cible, date_cotation, taux,
    source_provider, loaded_at
)
FROM @fintrack_stage/raw_fx_rates.csv.gz
FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
ON_ERROR = 'ABORT_STATEMENT';

-- Comptes
COPY INTO raw_comptes (
    compte_id, tenant_id, numero_compte, iban, bic, nom_client, prenom_client,
    email, telephone, date_naissance, adresse_ligne1, adresse_ligne2,
    code_postal, ville, pays, type_compte, devise, solde_initial,
    solde_actuel, date_ouverture, date_derniere_activite, statut,
    kyc_level, kyc_date_verification, aml_flag, customer_segment,
    preferred_language, consent_marketing, consent_data_sharing, is_pep,
    risk_score, created_at, updated_at, created_by_source_system
)
FROM @fintrack_stage/raw_comptes.csv.gz
FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
ON_ERROR = 'CONTINUE'
RETURN_FAILED_ONLY = TRUE;

-- Transactions — gros volume, ON_ERROR CONTINUE pour tolérance
COPY INTO raw_transactions (
    transaction_id, external_transaction_id, tenant_id, compte_id,
    compte_source_iban, compte_dest_iban, date_transaction, date_valeur,
    date_comptabilisation, date_reception, date_traitement, date_settlement,
    montant, devise, montant_eur, taux_change_applique, frais, frais_devise,
    montant_net, type_operation, sens, categorie_id, categorie_auto_detectee,
    confiance_categorie, sous_categorie, tags, marchand_nom, marchand_id,
    marchand_categorie, marchand_pays, marchand_mcc, marchand_siret,
    moyen_paiement, carte_id, carte_last4, carte_type, carte_reseau,
    authentification_3ds, canal, device_type, device_id, user_agent,
    ip_address, session_id, geolocation_lat, geolocation_lon, statut,
    statut_precedent, nb_tentatives, date_derniere_tentative, raison_rejet,
    code_erreur, message_erreur, aml_score, aml_flag, aml_reviewed_by,
    aml_review_date, fraud_score, fraud_rules_triggered, is_flagged_for_review,
    is_reconciled, date_reconciliation, reconciliation_batch_id,
    external_reference, internal_reference, description, description_brute,
    description_enrichie, libelle_court, source_system, source_file_batch_id,
    created_at, updated_at, loaded_at, processing_version, is_test,
    is_reversal, original_transaction_id
)
FROM @fintrack_stage/raw_transactions.csv.gz
FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
ON_ERROR = 'CONTINUE'
RETURN_FAILED_ONLY = TRUE;

-- Virements
COPY INTO raw_virements (
    virement_id, tenant_id, compte_source_id, compte_dest_id, montant,
    devise, date_virement, date_execution, motif, reference, statut,
    type_virement, frais, created_at, updated_at
)
FROM @fintrack_stage/raw_virements.csv.gz
FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
ON_ERROR = 'CONTINUE'
RETURN_FAILED_ONLY = TRUE;

-- Titulaires
COPY INTO raw_titulaires (
    titulaire_id, nom, prenom, email, telephone, date_naissance
)
FROM @fintrack_stage/raw_titulaires.csv.gz
FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
ON_ERROR = 'ABORT_STATEMENT';

-- Bridge comptes <-> titulaires
COPY INTO raw_compte_titulaires (
    compte_id, titulaire_id, allocation_factor, date_debut, date_fin, is_primary
)
FROM @fintrack_stage/raw_compte_titulaires.csv.gz
FILE_FORMAT = (FORMAT_NAME = ff_csv_gz)
ON_ERROR = 'ABORT_STATEMENT';

-- ============================================
-- VALIDATION POST-LOAD
-- ============================================
SELECT 'raw_tenants'      AS table_name, COUNT(*) AS row_count FROM raw_tenants
UNION ALL SELECT 'raw_categories',    COUNT(*) FROM raw_categories
UNION ALL SELECT 'raw_fx_rates',      COUNT(*) FROM raw_fx_rates
UNION ALL SELECT 'raw_comptes',       COUNT(*) FROM raw_comptes
UNION ALL SELECT 'raw_transactions',  COUNT(*) FROM raw_transactions
UNION ALL SELECT 'raw_virements',     COUNT(*) FROM raw_virements
UNION ALL SELECT 'raw_titulaires',        COUNT(*) FROM raw_titulaires
UNION ALL SELECT 'raw_compte_titulaires', COUNT(*) FROM raw_compte_titulaires
ORDER BY table_name;

-- ============================================
-- MONITORING : historique des COPY
-- ============================================
SELECT file_name, status, row_count, row_parsed, error_count, last_load_time
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'RAW.RAW_TRANSACTIONS',
    START_TIME => DATEADD(HOUR, -1, CURRENT_TIMESTAMP())
))
ORDER BY last_load_time DESC;
