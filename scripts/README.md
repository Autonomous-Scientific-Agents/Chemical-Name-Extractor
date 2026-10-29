# Dataset downloads for the Chemical Name Extractor

`download_datasets.sh` fetches the open name/structure datasets into `scripts/data/<source>/` by default (use `--dest` to put them elsewhere). The `data/` folder is git-ignored.

| Source | Files | License |
|---|---|---|
| pubchem | CID-Synonym-filtered, CID-Title, CID-InChI-Key, CID-SMILES (`.gz`) | Public domain |
| chebi | names, compounds, database_accession, structures (TSV), SDF, OBO | CC BY 4.0 |
| chembl | latest `chembl_NN_sqlite.tar.gz` (synonyms in `molecule_synonyms`), chemreps, sha256-checked | CC BY-SA 3.0 |
| unichem | table dumps: source, structure (InChIKey), reference (cross-IDs) | CC0 |
| drugbank | open vocabulary CSV (+ open structures if available) | CC0 |
| unii | FDA GSRS `UNII_Data.zip` (names + InChIKey/SMILES) | Public domain |
| comptox | newest DSSTox synonym / identifier files found on the EPA FTP | Public domain |

Full DrugBank, CAS Registry, Reaxys and other license-restricted sources are skipped on purpose.

## Run

```bash
cd Chemical-Name-Extractor/scripts
chmod +x download_datasets.sh
# macOS: keep the machine awake and keep running if the terminal closes
nohup caffeinate -i ./download_datasets.sh > download.out 2>&1 &
# Linux: nohup ./download_datasets.sh > download.out 2>&1 &
tail -f data/download.log
```

- Needs about 60 GB free (compressed download is ~48 GB; the script checks before starting). Plan for roughly 3x that once files are decompressed.
- Pick sources: `./download_datasets.sh pubchem chebi unii`. UniChem is the biggest; leave it out if space is tight.
- Resume: just run the same command again. Finished files are skipped and `*.part` files continue where they stopped.
- `--verify` runs `gzip -t`/`unzip -t` on each finished file. `--dest /Volumes/Big/chem` writes somewhere else.
- Exit code 2 means some items failed; the log lists them with a manual download link where one exists.

Some download URLs have not been tested end to end yet, so ChEBI, DrugBank and CompTox try a few known layouts. If one still fails, the log says which.
