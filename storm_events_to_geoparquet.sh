#!/usr/bin/env bash

################################################################################
# Combine CSV Files → Spatial GeoParquet using ogr2ogr append
#
# Takes downloaded/extracted NOAA Storm Events CSV files and combines them
# into a single spatial GeoParquet file using ogr2ogr append.
#
# Workflow:
#   1. Download .csv.gz files from NOAA (optional)
#   2. Extract .csv.gz to .csv
#   3. Use ogr2ogr to append all CSVs to intermediate GeoPackage
#   4. Convert final GeoPackage to spatial GeoParquet
#
# Usage:
#   ./storm_events_csv_to_geoparquet.sh                    # Download all years → GeoParquet
#   ./storm_events_csv_to_geoparquet.sh -y 2022            # Download single year
#   ./storm_events_csv_to_geoparquet.sh -s 2022 -e 2026    # Year range
#   ./storm_events_csv_to_geoparquet.sh -f gpkg            # Output as GeoPackage
#   ./storm_events_csv_to_geoparquet.sh -o output.parquet  # Custom output
#
# Options:
#   -h, --help         Show this help message
#   -y, --year YEAR    Single year to download
#   -s, --start YEAR   Start year (inclusive)
#   -e, --end YEAR     End year (inclusive)
#   -f, --format FORMAT Output format: parquet (default) or gpkg
#   -o, --output FILE  Output filename (default: storm_events_combined.parquet or .gpkg)
#
# Examples:
#   ./storm_events_csv_to_geoparquet.sh                          # All years → Parquet
#   ./storm_events_csv_to_geoparquet.sh -f gpkg                  # All years → GeoPackage
#   ./storm_events_csv_to_geoparquet.sh -y 2022                  # Year 2022 only → Parquet
#   ./storm_events_csv_to_geoparquet.sh -s 2020 -e 2023 -f gpkg   # Years 2020-2023 → GeoPackage
#   ./storm_events_csv_to_geoparquet.sh -o storms_2022_26.parquet # Custom Parquet output
#   ./storm_events_csv_to_geoparquet.sh -o storms.gpkg -f gpkg    # Custom GeoPackage output
#
# Requirements:
#   - ogr2ogr (from GDAL)
#   - curl (for downloading files)
#   - gunzip (for extracting files)
#
################################################################################

set -e          # Stop on first error
set -o pipefail # Catch failures inside pipelines

# ============================================================================
# STEP 1: Setup - Colors, paths, and configuration
# ============================================================================

# Color codes for terminal output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Icons for visual feedback
SUCCESS="✅"
ERROR="❌"
WARNING="⚠️"
INFO="ℹ️"
DOWNLOAD="⬇️"
PROCESS="⚙️"

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
                echo -e "${ERROR} Invalid format: $OUTPUT_FORMAT"
                echo -e "${INFO} Valid formats: parquet, gpkg"
                exit 1
            fi
            shift 2
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        *)
            echo -e "${ERROR} Unknown option: $1"
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

echo -e "${BLUE}"
echo "╔════════════════════════════════════════════════════════════╗"

if [ "$OUTPUT_FORMAT" = "gpkg" ]; then
    echo "║  NOAA Storm Events CSV → GeoPackage                       ║"
else
    echo "║  NOAA Storm Events CSV → Spatial GeoParquet                ║"
fi

echo "║  (Using ogr2ogr append)                                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Show filtering options
if [ -n "$SINGLE_YEAR" ]; then
    echo -e "${INFO} Filtering: Year $SINGLE_YEAR only"
elif [ -n "$YEAR_START" ] && [ -n "$YEAR_END" ]; then
    echo -e "${INFO} Filtering: Years $YEAR_START to $YEAR_END"
else
    echo -e "${INFO} Filtering: All available years"
fi

echo -e "${INFO} Output format: $OUTPUT_FORMAT"
echo ""

# ============================================================================
# STEP 5: Fetch list of available files from NOAA server
# ============================================================================

echo -e "${PROCESS} Step 1/6: Fetching file list from NOAA..."

LISTING=$(curl -sfL "$BASE_URL/" 2>/dev/null) || {
    echo -e "${ERROR} Could not reach NOAA server at $BASE_URL"
    echo -e "${INFO} Check your internet connection or try:"
    echo -e "${INFO} curl -I $BASE_URL/"
    exit 1
}

FILES=$(echo "$LISTING" | sed -nE 's/.*href="([^"]*StormEvents_details-ftp_v1[^"]*\.csv\.gz)".*/\1/p' | sort -u)

if [ -z "$FILES" ]; then
    echo -e "${ERROR} No matching files found at $BASE_URL"
    exit 1
fi

FILE_COUNT=$(echo "$FILES" | wc -l)
echo -e "${SUCCESS} Found $FILE_COUNT file(s) available"

# ============================================================================
# STEP 6: Filter files by year and detect duplicates
# ============================================================================

echo -e "\n${PROCESS} Step 2/6: Filtering by year and checking for duplicates..."

FILTERED_FILES=""
YEAR_FILE_PAIRS=""

for file in $FILES; do
    YEAR=$(echo "$file" | sed -nE 's/.*_d([0-9]{4})_.*/\1/p')
    
    if [ -z "$YEAR" ]; then
        echo -e "${WARNING} Could not extract year from: $file"
        continue
    fi
    
    # Apply year filter
    if [ -n "$SINGLE_YEAR" ]; then
        [ "$YEAR" != "$SINGLE_YEAR" ] && continue
    elif [ -n "$YEAR_START" ] && [ -n "$YEAR_END" ]; then
        if [ "$YEAR" -lt "$YEAR_START" ] || [ "$YEAR" -gt "$YEAR_END" ]; then
            continue
        fi
    fi
    
    YEAR_FILE_PAIRS="$YEAR_FILE_PAIRS
$YEAR:$file"
    
    FILTERED_FILES="$FILTERED_FILES
$file"
done

FILTERED_FILES=$(echo "$FILTERED_FILES" | grep -v '^$' || true)
YEAR_FILE_PAIRS=$(echo "$YEAR_FILE_PAIRS" | grep -v '^$' || true)

if [ -z "$FILTERED_FILES" ]; then
    echo -e "${ERROR} No files match your year filter"
    exit 1
fi

FILTERED_COUNT=$(echo "$FILTERED_FILES" | wc -l)
echo -e "${SUCCESS} Selected $FILTERED_COUNT file(s) to process"

# Warn about duplicates
DUPLICATE_YEARS=$(echo "$YEAR_FILE_PAIRS" | cut -d: -f1 | sort | uniq -c | awk '$1 > 1 {count++} END {print count}' || echo 0)

if [ "$DUPLICATE_YEARS" -gt 0 ]; then
    echo -e "\n${WARNING} Note: Multiple files exist for $DUPLICATE_YEARS year(s)"
    echo "$YEAR_FILE_PAIRS" | cut -d: -f1 | sort | uniq -c | awk '$1 > 1' | while read count year; do
        echo -e "${WARNING} Year $year has $count version(s)"
    done
fi

# ============================================================================
# STEP 7: Download files
# ============================================================================

echo -e "\n${PROCESS} Step 3/6: Downloading files..."

DOWNLOAD_COUNT=0

for file in $FILTERED_FILES; do
    FILEPATH="$DATA_DIR/$file"
    
    if [ -f "$FILEPATH" ]; then
        echo -e "${INFO} Already downloaded: $file"
    else
        echo -e "${DOWNLOAD} Downloading: $file"
        if curl -L --progress-bar -o "$FILEPATH" "$BASE_URL/$file" 2>/dev/null; then
            SIZE=$(wc -c < "$FILEPATH" | tr -d ' ')
            if [ "$SIZE" -lt 10000 ]; then
                echo -e "${ERROR} Download may have failed (only $SIZE bytes)"
                rm "$FILEPATH"
                continue
            fi
            echo -e "${SUCCESS} Downloaded ($SIZE bytes)"
            ((DOWNLOAD_COUNT++))
        else
            echo -e "${ERROR} Download failed"
            continue
        fi
    fi
done

if [ $DOWNLOAD_COUNT -eq 0 ]; then
    echo -e "${WARNING} No new files downloaded (may already exist)"
fi

# ============================================================================
# STEP 8: Extract CSV files
# ============================================================================

echo -e "\n${PROCESS} Step 4/6: Extracting CSV files..."

CSV_FILES=""
EXTRACTED_COUNT=0

for file in $FILTERED_FILES; do
    CSV_FILE="${file%.gz}"
    FILEPATH="$DATA_DIR/$file"
    CSV_PATH="$DATA_DIR/$CSV_FILE"
    
    if [ ! -f "$CSV_PATH" ]; then
        echo -e "${PROCESS} Extracting: $CSV_FILE"
        if gunzip -c "$FILEPATH" > "$CSV_PATH"; then
            echo -e "${SUCCESS} Extracted"
            CSV_FILES="$CSV_FILES
$CSV_PATH"
            ((EXTRACTED_COUNT++))
        else
            echo -e "${ERROR} Failed to extract $CSV_FILE"
        fi
    else
        echo -e "${INFO} Already extracted: $CSV_FILE"
        CSV_FILES="$CSV_FILES
$CSV_PATH"
    fi
done

CSV_FILES=$(echo "$CSV_FILES" | grep -v '^$' || true)

if [ -z "$CSV_FILES" ]; then
    echo -e "${ERROR} No CSV files available"
    exit 1
fi

echo -e "${SUCCESS} Extracted $EXTRACTED_COUNT file(s)"

# ============================================================================
# STEP 9: Combine CSV files using ogr2ogr append to GeoPackage
# ============================================================================

echo -e "\n${PROCESS} Step 5/6: Combining CSV files using ogr2ogr append..."

TEMP_GPKG="$TEMP_DIR/combined.gpkg"
FIRST=true
APPEND_COUNT=0
TOTAL_COMBINED=0

while IFS= read -r csv_file; do
    [ -z "$csv_file" ] && continue
    
    filename=$(basename "$csv_file")
    
    if [ "$FIRST" = true ]; then
        echo -e "${PROCESS} Initializing GeoPackage with: $filename"
        
        # Convert first CSV to GeoPackage with geometry
        if ogr2ogr -f GPKG \
            -oo X_POSSIBLE_NAMES=BEGIN_LON \
            -oo Y_POSSIBLE_NAMES=BEGIN_LAT \
            -a_srs EPSG:4326 \
            "$TEMP_GPKG" \
            "$csv_file" 2>/dev/null; then
            
            echo -e "${SUCCESS} Initialized GeoPackage"
            FIRST=false
            ((TOTAL_COMBINED++))
        else
            echo -e "${ERROR} Failed to initialize GeoPackage with $filename"
            exit 1
        fi
    else
        echo -e "${PROCESS} Appending: $filename"
        
        # Append remaining CSVs to GeoPackage layer
        if ogr2ogr -f GPKG \
            -append \
            -nln combined \
            -oo X_POSSIBLE_NAMES=BEGIN_LON \
            -oo Y_POSSIBLE_NAMES=BEGIN_LAT \
            "$TEMP_GPKG" \
            "$csv_file" 2>/dev/null; then
            
            echo -e "${SUCCESS} Appended"
            ((APPEND_COUNT++))
            ((TOTAL_COMBINED++))
        else
            echo -e "${WARNING} Failed to append $filename (will skip)"
        fi
    fi
done <<EOF
$CSV_FILES
EOF

if [ ! -f "$TEMP_GPKG" ]; then
    echo -e "${ERROR} Failed to create combined GeoPackage"
    exit 1
fi

GPKG_FEATURES=$(ogrinfo -so "$TEMP_GPKG" 2>/dev/null | grep "Feature Count" | grep -oE '[0-9]+' | head -1 || echo "unknown")
echo -e "${SUCCESS} Combined $TOTAL_COMBINED CSV file(s)"
echo -e "${INFO}   Total features: $GPKG_FEATURES"

# ============================================================================
# STEP 10: Convert to final format or use GeoPackage directly
# ============================================================================

if [ "$OUTPUT_FORMAT" = "gpkg" ]; then
    echo -e "\n${PROCESS} Step 6/6: Using GeoPackage as final output..."
    
    # Copy GeoPackage to output location
    if cp "$TEMP_GPKG" "$OUTPUT_FILE"; then
        echo -e "${SUCCESS} GeoPackage ready: $OUTPUT_FILE"
    else
        echo -e "${ERROR} Failed to copy GeoPackage to output location"
        exit 1
    fi
else
    echo -e "\n${PROCESS} Step 6/6: Converting to spatial GeoParquet..."
    
    echo -e "${PROCESS} Creating Point geometry from BEGIN_LON/BEGIN_LAT..."
    echo -e "${PROCESS} Setting coordinate system to EPSG:4326 (WGS84)..."
    
    if ogr2ogr -f Parquet \
        -a_srs EPSG:4326 \
        "$OUTPUT_FILE" \
        "$TEMP_GPKG" \
        "combined" 2>/dev/null; then
        
        echo -e "${SUCCESS} Converted to spatial GeoParquet"
    else
        echo -e "${ERROR} Failed to convert to GeoParquet"
        exit 1
    fi
fi

# ============================================================================
# STEP 11: Verify output
# ============================================================================

echo -e "\n${PROCESS} Verifying output..."

if [ ! -f "$OUTPUT_FILE" ]; then
    echo -e "${ERROR} Output file not found: $OUTPUT_FILE"
    exit 1
fi

SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
FEATURE_COUNT=$(ogrinfo -so "$OUTPUT_FILE" 2>/dev/null | grep "Feature Count" | grep -oE '[0-9]+' | head -1 || echo "unknown")

echo -e "${SUCCESS} Verification complete"

# ============================================================================
# Summary
# ============================================================================

echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗"
echo "║  ✅ Conversion Complete!                                     ║"
echo "╚════════════════════════════════════════════════════════════╝${NC}"

echo -e "\n${INFO} Processing Summary:"
echo -e "   Input CSV files: $TOTAL_COMBINED"
echo -e "   Combined features: $FEATURE_COUNT"
echo -e "   Output file: $OUTPUT_FILE"
echo -e "   Output size: $SIZE"
FORMAT_DISPLAY=$(echo "$OUTPUT_FORMAT" | tr '[:lower:]' '[:upper:]')
echo -e "   Output format: $FORMAT_DISPLAY"
echo -e "   Geometry type: Point"
echo -e "   Coordinate system: EPSG:4326 (WGS84)"

echo -e "\n${INFO} Next steps to open in QGIS:"
echo -e "   1. Open QGIS 3.0+"
echo -e "   2. Layer → Add Layer → Add Vector Layer"
echo -e "   3. Select: $OUTPUT_FILE"
echo -e "   4. Storm events will display as points on the map"

if [ "$OUTPUT_FORMAT" = "gpkg" ]; then
    echo -e "\n${INFO} File is ready for:"
    echo -e "   • QGIS analysis and visualization"
    echo -e "   • ArcGIS Pro"
    echo -e "   • PostGIS database import"
    echo -e "   • SpatiaLite queries"
    echo -e "   • Any GIS software supporting GeoPackage"
else
    echo -e "\n${INFO} File is ready for:"
    echo -e "   • QGIS analysis and visualization"
    echo -e "   • ArcGIS Pro"
    echo -e "   • PostGIS database import"
    echo -e "   • Any GIS software supporting GeoParquet"
fi

# ============================================================================
# STEP 12: Cleanup
# ============================================================================

read -p "$(echo -e ${BLUE})Clean up temporary files? (y/n)${NC} " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${PROCESS} Cleaning up..."
    rm -rf "$TEMP_DIR"
    echo -e "${SUCCESS} Cleanup complete"
fi

exit 0
