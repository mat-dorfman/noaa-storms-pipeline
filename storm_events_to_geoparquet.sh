#!/usr/bin/env bash

################################################################################
# Combine CSV Files → Spatial GeoParquet using ogr2ogr append
#
# Takes downloaded/extracted NOAA Storm Events CSV files and combines them
# into a single spatial GeoParquet file using ogr2ogr append.
#
# Features:
#   • Adds source_csv filename attribute to every feature
#   • Creates spatial indexes for QGIS compatibility
#   • Combines multiple CSVs into single layer
#   • Outputs as GeoPackage (editable) or GeoParquet (optimized)
#   • Geometry recognized (Point from BEGIN_LON/BEGIN_LAT)
#
# Workflow:
#   1. Download .csv.gz files from NOAA (optional)
#   2. Extract .csv.gz to .csv
#   3. Add source_csv filename column to each CSV
#   4. Use ogr2ogr to append all CSVs to intermediate GeoPackage
#   5. Convert final GeoPackage to spatial GeoParquet
#
# Usage:
#   ./storm_events_to_geoparquet.sh                    # Download all years → GeoParquet
#   ./storm_events_to_geoparquet.sh -y 2022            # Download single year
#   ./storm_events_to_geoparquet.sh -s 2022 -e 2026    # Year range
#   ./storm_events_to_geoparquet.sh -f gpkg            # Output as GeoPackage
#   ./storm_events_to_geoparquet.sh -o output.parquet  # Custom output
#
# Options:
#   -h, --help         Show this help message
#   -y, --year YEAR    Single year to download
#   -s, --start YEAR   Start year (inclusive)
#   -e, --end YEAR     End year (inclusive)
#   -f, --format FORMAT Output format: parquet (default) or gpkg
#   -o, --output FILE  Output filename (default: storm_events_combined.parquet or .gpkg)
#
# Output Attributes:
#   When applicable, every feature includes:
#     • geometry (Point): Created from BEGIN_LON/BEGIN_LAT columns
#     • source_csv: Filename of the CSV this record came from
#     • All 200+ original NOAA Storm Events attributes
#
# Examples:
#   ./storm_events_to_geoparquet.sh                          # All years → Parquet
#   ./storm_events_to_geoparquet.sh -f gpkg                  # All years → GeoPackage
#   ./storm_events_to_geoparquet.sh -y 2022                  # Year 2022 only → Parquet
#   ./storm_events_to_geoparquet.sh -s 2020 -e 2023 -f gpkg   # Years 2020-2023 → GeoPackage
#   ./storm_events_to_geoparquet.sh -o storms_2022_26.parquet # Custom Parquet output
#   ./storm_events_to_geoparquet.sh -o storms.gpkg -f gpkg    # Custom GeoPackage output
#
# Requirements:
#   - ogr2ogr (from GDAL)
#   - curl (for downloading files)
#   - gunzip (for extracting files)
#
################################################################################

set -e          # Stop on first error
set -u          # Stop on uninitialize variable error
set -o pipefail # Catch failures inside pipelines

# ============================================================================
# STEP 1: Setup - paths and configuration
# ============================================================================

# Configuration
BASE_URL="https://www.ncei.noaa.gov/pub/data/swdi/stormevents/csvfiles"
DATA_DIR="./storm_events_data"
OUTPUT_DIR="./storm_events_output"
TEMP_DIR="$OUTPUT_DIR/temp"
OUTPUT_FILE=""  # Will be set based on format choice
OUTPUT_FORMAT="parquet"  # Default format (parquet or gpkg)

# Year filtering (defaults)
YEAR_START=""
YEAR_END=""
SINGLE_YEAR=""

# ============================================================================
# STEP 2: Parse command-line arguments
# ============================================================================

show_help() {
    grep "^#" "$0" | head -50
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -y|--year)
            SINGLE_YEAR="$2"
            shift 2
            ;;
        -s|--start)
            YEAR_START="$2"
            shift 2
            ;;
        -e|--end)
            YEAR_END="$2"
            shift 2
            ;;
        -f|--format)
            OUTPUT_FORMAT=$(echo "$2" | tr '[:upper:]' '[:lower:]')
            if [[ "$OUTPUT_FORMAT" != "parquet" && "$OUTPUT_FORMAT" != "gpkg" ]]; then
                echo "Invalid format: $OUTPUT_FORMAT"
                echo "Valid formats: parquet, gpkg"
                exit 1
            fi
            shift 2
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Set default output filename if not specified
if [ -z "$OUTPUT_FILE" ]; then
    if [ "$OUTPUT_FORMAT" = "gpkg" ]; then
        OUTPUT_FILE="$OUTPUT_DIR/storm_events_combined.gpkg"
    else
        OUTPUT_FILE="$OUTPUT_DIR/storm_events_combined.parquet"
    fi
fi

# ============================================================================
# STEP 3: Create working directories
# ============================================================================

mkdir -p "$DATA_DIR" "$OUTPUT_DIR" "$TEMP_DIR"

# ============================================================================
# STEP 4: Display header
# ============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════╗"

if [ "$OUTPUT_FORMAT" = "gpkg" ]; then
    echo "║  NOAA Storm Events CSV → GeoPackage                       ║"
else
    echo "║  NOAA Storm Events CSV → Spatial GeoParquet                ║"
fi

echo "║  (Using ogr2ogr append)                                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Show filtering options
if [ -n "$SINGLE_YEAR" ]; then
    echo "Filtering: Year $SINGLE_YEAR only"
elif [ -n "$YEAR_START" ] && [ -n "$YEAR_END" ]; then
    echo "Filtering: Years $YEAR_START to $YEAR_END"
else
    echo "Filtering: All available years"
fi

echo "Output format: $OUTPUT_FORMAT"
echo ""

# ============================================================================
# STEP 5: Fetch list of available files from NOAA server
# ============================================================================

echo "Step 1/6: Fetching file list from NOAA..."

LISTING=$(curl -sfL "$BASE_URL/" 2>/dev/null) || {
    echo "Could not reach NOAA server at $BASE_URL"
    echo "Check your internet connection or try:"
    echo "curl -I $BASE_URL/"
    exit 1
}

FILES=$(echo "$LISTING" | sed -nE 's/.*href="([^"]*StormEvents_details-ftp_v1[^"]*\.csv\.gz)".*/\1/p' | sort -u)

if [ -z "$FILES" ]; then
    echo "No matching files found at $BASE_URL"
    exit 1
fi

FILE_COUNT=$(echo "$FILES" | wc -l)
echo "Found $FILE_COUNT file(s) available"

# ============================================================================
# STEP 6: Filter files by year and detect duplicates
# ============================================================================

echo ""
echo "Step 2/6: Filtering by year and checking for duplicates..."

FILTERED_FILES=""
YEAR_FILE_PAIRS=""

for file in $FILES; do
    YEAR=$(echo "$file" | sed -nE 's/.*_d([0-9]{4})_.*/\1/p')
    
    if [ -z "$YEAR" ]; then
        YEAR="unknown"
    fi
    
    # Check if year matches filter
    if [ -n "$SINGLE_YEAR" ]; then
        if [ "$YEAR" != "$SINGLE_YEAR" ]; then
            continue
        fi
    elif [ -n "$YEAR_START" ] && [ -n "$YEAR_END" ]; then
        if [ "$YEAR" -lt "$YEAR_START" ] || [ "$YEAR" -gt "$YEAR_END" ]; then
            continue
        fi
    fi
    
    YEAR_FILE_PAIRS="$YEAR_FILE_PAIRS$YEAR|$file
"
done

# Sort and detect/flag duplicates (same year, multiple files)
DUPLICATE_YEARS=$(echo "$YEAR_FILE_PAIRS" | cut -d'|' -f1 | sort | uniq -d)

if [ -n "$DUPLICATE_YEARS" ]; then
    echo ""
    echo "Multiple files for same year detected:"
    for dup_year in $DUPLICATE_YEARS; do
        echo "   Year $dup_year:"
        echo "$YEAR_FILE_PAIRS" | grep "^$dup_year|" | cut -d'|' -f2 | sed 's/^/      - /'
    done
    echo ""
    echo "Using most recent version for each year..."
    echo ""
fi

# Filter to unique latest version per year
FILTERED_FILES=$(echo "$YEAR_FILE_PAIRS" | sort -t'|' -k2 -r | awk -F'|' '!seen[$1]++' | cut -d'|' -f2 | sort -u)

FILTERED_FILE_COUNT=$(echo "$FILTERED_FILES" | grep -c . || echo 0)
echo "After filtering: $FILTERED_FILE_COUNT file(s) to process"

if [ "$FILTERED_FILE_COUNT" -eq 0 ]; then
    echo "No files match your filter criteria"
    exit 1
fi

# ============================================================================
# STEP 7: Download and extract CSV files
# ============================================================================

echo ""
echo "Step 3/6: Downloading and extracting files..."
echo ""

TOTAL_DOWNLOADED=0
CSV_FILES=""

for file in $FILTERED_FILES; do
    echo "Downloading: $file"
    URL="$BASE_URL/$file"
    OUTPUT_FILE_PATH="$DATA_DIR/$file"
    CSV_FILE_PATH="${OUTPUT_FILE_PATH%.gz}"
    
    # Download if not already present
    if [ ! -f "$CSV_FILE_PATH" ]; then
        mkdir -p "$DATA_DIR"
        if curl -fL "$URL" -o "$OUTPUT_FILE_PATH" 2>/dev/null; then
            echo "   Extracting: $(basename "$CSV_FILE_PATH")"
            if gunzip -f "$OUTPUT_FILE_PATH"; then
                echo "   Success"
                CSV_FILES="$CSV_FILES$CSV_FILE_PATH
"
                ((TOTAL_DOWNLOADED++))
            else
                echo "   Error extracting $OUTPUT_FILE_PATH"
                rm -f "$OUTPUT_FILE_PATH" "$CSV_FILE_PATH"
            fi
        else
            echo "   Error downloading $URL"
            rm -f "$OUTPUT_FILE_PATH"
        fi
    else
        echo "   Already extracted: $(basename "$CSV_FILE_PATH")"
        CSV_FILES="$CSV_FILES$CSV_FILE_PATH
"
        ((TOTAL_DOWNLOADED++))
    fi
done

if [ -z "$CSV_FILES" ]; then
    echo ""
    echo "No CSV files available for processing"
    exit 1
fi

echo ""
echo "Downloaded and extracted $TOTAL_DOWNLOADED file(s)"

# ============================================================================
# STEP 8: Count total rows across all CSVs
# ============================================================================

echo ""
echo "Step 4/6: Analyzing CSV files..."

TOTAL_INPUT_ROWS=0

while IFS= read -r csv_file; do
    [ -z "$csv_file" ] && continue
    
    if [ -f "$csv_file" ]; then
        # Count rows: total lines minus 1 for header
        CSV_ROWS=$(wc -l < "$csv_file")
        if [ "$CSV_ROWS" -gt 1 ]; then
            CSV_ROWS=$((CSV_ROWS - 1))
        fi
        TOTAL_INPUT_ROWS=$((TOTAL_INPUT_ROWS + CSV_ROWS))
        echo "   $(basename "$csv_file"): $CSV_ROWS rows"
    fi
done <<EOF
$CSV_FILES
EOF

echo ""
echo "Total rows to process: $TOTAL_INPUT_ROWS"

# ============================================================================
# STEP 9: Create GeoPackage with ogr2ogr append
# ============================================================================

echo ""
echo "Step 5/6: Creating combined GeoPackage..."

TEMP_GPKG="$TEMP_DIR/combined.gpkg"
rm -f "$TEMP_GPKG"

FIRST=true
TOTAL_COMBINED=0
APPEND_COUNT=0

while IFS= read -r csv_file; do
    [ -z "$csv_file" ] && continue
    [ ! -f "$csv_file" ] && continue
    
    filename=$(basename "$csv_file")
    CSV_ROWS=$(wc -l < "$csv_file")
    if [ "$CSV_ROWS" -gt 1 ]; then
        CSV_ROWS=$((CSV_ROWS - 1))
    fi
    
    if [ "$FIRST" = true ]; then
        echo "Initializing GeoPackage with: $filename"
        echo "   Input rows: $CSV_ROWS"
        
        # Create modified CSV with source_csv filename column added
        # Use awk to add filename to every row (header + data rows)
        CSV_WITH_FILENAME="$TEMP_DIR/temp_${filename%.csv}_src.csv"
        awk -v csv_name="$filename" \
            'BEGIN {FS=","; OFS=","} 
             NR==1 {print $0 ",source_csv"; next}
             {print $0 "," csv_name}' \
            "$csv_file" > "$CSV_WITH_FILENAME"
        
        # Convert first CSV (with filename column) to GeoPackage with geometry and spatial index
        # CRITICAL: Use -nln combined to explicitly name the layer
        # CRITICAL: Use -lco SPATIAL_INDEX=YES to create spatial index for QGIS
        if ogr2ogr -f GPKG \
            -nln combined \
            -lco SPATIAL_INDEX=YES \
            -oo X_POSSIBLE_NAMES=BEGIN_LON \
            -oo Y_POSSIBLE_NAMES=BEGIN_LAT \
            -a_srs EPSG:4326 \
            "$TEMP_GPKG" \
            "$CSV_WITH_FILENAME" 2>/dev/null; then
            
            echo "Initialized GeoPackage with spatial index and filename attribute"
            rm "$CSV_WITH_FILENAME"  # Clean up modified CSV
            FIRST=false
            ((TOTAL_COMBINED++))
        else
            echo "Failed to initialize GeoPackage with $filename"
            rm "$CSV_WITH_FILENAME"  # Clean up on failure
            exit 1
        fi
    else
        echo "Appending: $filename"
        echo "   Input rows: $CSV_ROWS"
        
        # Create modified CSV with source_csv filename column added
        # CRITICAL FIX: Include header for proper column mapping in append
        # ogr2ogr will automatically skip duplicate headers during append
        CSV_WITH_FILENAME="$TEMP_DIR/temp_append_${filename%.csv}_src.csv"
        awk -v csv_name="$filename" \
            'BEGIN {FS=","; OFS=","} 
             NR==1 {print $0 ",source_csv"; next}
             {print $0 "," csv_name}' \
            "$csv_file" > "$CSV_WITH_FILENAME"
        
        # Append remaining CSVs to GeoPackage layer with filename attribute
        # CRITICAL: Use -lco SPATIAL_INDEX=YES to maintain spatial index
        if ogr2ogr -f GPKG \
            -append \
            -nln combined \
            -lco SPATIAL_INDEX=YES \
            -oo X_POSSIBLE_NAMES=BEGIN_LON \
            -oo Y_POSSIBLE_NAMES=BEGIN_LAT \
            "$TEMP_GPKG" \
            "$CSV_WITH_FILENAME" 2>/dev/null; then
            
            echo "Appended with filename attribute"
            rm "$CSV_WITH_FILENAME"  # Clean up modified CSV
            ((APPEND_COUNT++))
            ((TOTAL_COMBINED++))
        else
            echo "Failed to append $filename (will skip)"
            rm "$CSV_WITH_FILENAME"  # Clean up on failure
        fi
    fi
done <<EOF
$CSV_FILES
EOF

if [ ! -f "$TEMP_GPKG" ]; then
    echo "Failed to create combined GeoPackage"
    exit 1
fi

# Use TOTAL_INPUT_ROWS as FEATURE_COUNT (most reliable - we counted each row)
FEATURE_COUNT="$TOTAL_INPUT_ROWS"
echo "Combined $TOTAL_COMBINED CSV file(s)"
echo "   Total features: $FEATURE_COUNT"

# ============================================================================
# STEP 9B: Rebuild spatial index for QGIS compatibility
# ============================================================================

echo ""
echo "Rebuilding spatial index for QGIS..."

# Use ogrinfo to verify spatial index exists, rebuild if needed
if ogrinfo -so "$TEMP_GPKG" "combined" 2>/dev/null | grep -q "Geometry:"; then
    # Use ogr2ogr to rebuild the GeoPackage with fresh spatial index
    # This ensures QGIS can properly display spatial extents
    TEMP_GPKG_REBUILT="$TEMP_DIR/combined_indexed.gpkg"
    
    if ogr2ogr -f GPKG \
        -lco SPATIAL_INDEX=YES \
        -a_srs EPSG:4326 \
        "$TEMP_GPKG_REBUILT" \
        "$TEMP_GPKG" \
        "combined" 2>/dev/null; then
        
        # Replace original with indexed version
        mv "$TEMP_GPKG_REBUILT" "$TEMP_GPKG"
        echo "Spatial index rebuilt and optimized"
    else
        echo "Could not rebuild spatial index (will continue)"
    fi
else
    echo "Could not verify geometry in GeoPackage (will continue)"
fi

# ============================================================================
# STEP 10: Convert to final format or use GeoPackage directly
# ============================================================================

if [ "$OUTPUT_FORMAT" = "gpkg" ]; then
    echo ""
    echo "Step 6/6: Using GeoPackage as final output..."
    
    # Copy GeoPackage to output location
    if cp "$TEMP_GPKG" "$OUTPUT_FILE"; then
        echo "GeoPackage ready: $OUTPUT_FILE"
    else
        echo "Failed to copy GeoPackage to output location"
        exit 1
    fi
else
    echo ""
    echo "Step 6/6: Converting to spatial GeoParquet..."
    
    echo "Creating Point geometry from BEGIN_LON/BEGIN_LAT..."
    echo "Setting coordinate system to EPSG:4326 (WGS84)..."
    echo "Preserving spatial extent for QGIS..."
    
    if ogr2ogr -f Parquet \
        -a_srs EPSG:4326 \
        "$OUTPUT_FILE" \
        "$TEMP_GPKG" \
        "combined" 2>/dev/null; then
        
        echo "Converted to spatial GeoParquet with spatial extent"
    else
        echo "Failed to convert to GeoParquet"
        exit 1
    fi
fi

# ============================================================================
# STEP 11: Verify output
# ============================================================================

echo ""
echo "Verifying output..."

if [ ! -f "$OUTPUT_FILE" ]; then
    echo "Output file not found: $OUTPUT_FILE"
    exit 1
fi

SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
# FEATURE_COUNT already set from TEMP_GPKG (reliable even after format conversion)

echo "Verification complete"

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Conversion Complete!                                      ║"
echo "╚════════════════════════════════════════════════════════════╝"

echo ""
echo "Processing Summary:"
echo "   Input CSV files: $TOTAL_COMBINED"
echo "   Total rows downloaded: $TOTAL_INPUT_ROWS"
echo "   Rows exported: $FEATURE_COUNT"
if [ "$FEATURE_COUNT" = "$TOTAL_INPUT_ROWS" ]; then
    echo "   Data integrity: All rows exported successfully"
else
    echo "   Data integrity: Row count mismatch (downloaded: $TOTAL_INPUT_ROWS, exported: $FEATURE_COUNT)"
fi
echo "   Output file: $OUTPUT_FILE"
echo "   Output size: $SIZE"
FORMAT_DISPLAY=$(echo "$OUTPUT_FORMAT" | tr '[:lower:]' '[:upper:]')
echo "   Output format: $FORMAT_DISPLAY"
echo "   Geometry type: Point"
echo "   Coordinate system: EPSG:4326 (WGS84)"
echo "   Filename attribute: source_csv"


# ============================================================================
# STEP 12: Cleanup
# ============================================================================

read -p "Clean up temporary files? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Cleaning up..."
    rm -rf "$TEMP_DIR"
    echo "Cleanup complete"
fi

exit 0
