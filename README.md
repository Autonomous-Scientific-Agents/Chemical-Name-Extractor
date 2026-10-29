# Chemical Name Extractor

Find chemical names in text and map each one to a unique database ID (PubChem CID, InChIKey) and SMILES, using a fast local lookup built from open datasets.

Project page: https://autonomous-scientific-agents.github.io/Chemical-Name-Extractor/

## Approach

- **Dictionary**: PubChem FTP "Extras" (synonyms, titles, SMILES, InChIKeys) as the backbone, joined by InChIKey with ChEBI, ChEMBL, DrugBank, FDA UNII and EPA CompTox (or via UniChem).
- **Matching**: Aho-Corasick over a cleaned, normalized lexicon, plus regexes for CAS RNs, InChIKeys and formulas.
- **Unseen names**: an NER model (ChemDataExtractor 2, HunFlair2 or scispaCy) for candidate spans, resolved to structures with OPSIN.
- **Evaluation**: CHEMDNER, BC5CDR and NLM-Chem, scored on span F1 and CID accuracy.

## Data

`scripts/download_datasets.sh` downloads the open sources (about 48 GB compressed). See [scripts/README.md](scripts/README.md).

```bash
cd scripts
./download_datasets.sh pubchem chebi unii
```

## Layout

- `docs/` - GitHub Pages site
- `scripts/` - dataset download script

## License

Apache 2.0 for the code in this repository. Each dataset keeps its own license.
