-- Token-identical to Elasticsearch's body_analyzer. Created separately because
-- CrateDB's /_sql takes one statement per request, and an analyzer is cluster
-- scoped so it survives DROP TABLE. Re-running CREATE is a no-op in CrateDB.
CREATE ANALYZER sb_body (
    TOKENIZER sb_nonalnum WITH (
        type = 'char_group',
        tokenize_on_chars = ['whitespace', 'punctuation', 'symbol']
    ),
    TOKEN_FILTERS (lowercase)
)
