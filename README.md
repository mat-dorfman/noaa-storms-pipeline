# NOAA Storms Pipeline

A one-command pipeline that downloads a year, a range of years, or all years (default) of NOAA Storm Events data, converts it to GeoPackage (optional export) and exports as GeoParquet (default), and lands it ready for analysis in DuckDB, GeoPandas, or QGIS.

## What it does

`storm_events_to_geoparquet.sh` takes a year, a range of years, or all years (default), downloads the raw `details` file from NOAA's public archive, decompresses it at `storm_events_data/`, checks for duplicate years, populates a source file column with the report name (`StormEvents_details-ftp_v1.0_dDATAYYYY_cCREATEDYYYYMMDD.csv`) and converts it to a single GeoPackage or GeoParquet file at `storm_events_output/storm_events_combined.parquet`.

Total runtime: about 6.5 minutes for all 77 years on a home internet connection or about 1.5 minutes for a single year.

## The data

- **Source:** [NOAA Storm Events Database](https://www.ncei.noaa.gov/data/storm-events/)
- **License:** Public domain (US federal data)
- **What's in it:** every recorded storm event in the United States for the given year, including type, location, and damages

## How to run it

Requires GDAL (for `ogr2ogr`) and standard Unix utilities (`awk`, `curl`, `gunzip`).

```bash
git clone https://github.com/{mat-dorfman}/noaa-storms-pipeline.git
cd noaa-storms-pipeline
chmod +x storm_events_to_geoparquet.sh
./storm_events_to_geoparquet.sh
```

To run for a specific year:

```bash
./storm_events_to_geoparquet 2023
```

To run for a range of years:
```bash
./storm_events_to_geoparquet.sh -s 2022 -e 2026
```

To export to geopackage:
```bash
./storm_events_to_geoparquet.sh -f gpkg
```

To export to custom name:
```bash
./storm_events_to_geoparquet.sh -o output.parquet 
```

## What I learned

1.  Data pipeline optimization -> How to load a bunch of data into a usable format fast by leveraging the command line.
2.  AI problem solving strategy -> How to break a complex problem up into manageble steps by providing specific and explicit prompts.
3.  Version control orginization -> How to manage multiple iterations and document the development process.

## What I would do differently next time

1.  Use git for version control -> manual file organization is cumbersome.
2.  Maintain AI context -> incognito window exercise forces repetive prompts.
3.  Design with verification -> include manual testing mechanisms in the build.

## What I would change this time

1.  Remove the duplicate year functionality -> duplicate year datasets are not on the server.
2.  Remove the import vs export verification -> report number of rows in each file and the number of rows without geometry.
3.  Add a geometry only flag -> exclude records without point coordinates from export.

## Stack

- bash
- curl
- awk
- GDAL / ogr2ogr
- GeoParquet

## Acknowledgements

* This pipeline was prompted by Matt Forest's Spatial Lab: Modern GIS Accelerator Course (https://forrest.nyc/go/accelerator/) portfolio project. 

* Code was written with the help of AI.

## Citations
Anthropic. "Claude Haiku 4.5." Claude, version 4.5, 2025, claude.ai.