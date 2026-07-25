#!/usr/bin/env bash

################################################################################
# Download NOAA Storm Events and Convert to GeoParquet
#
# Simple command-line script to download storm event CSV files and combine
# them into a single GeoParquet file for use in QGIS.
#
# Usage:
#   ./storm_events_to_geoparquet.sh                    # Download all years
#   ./storm_events_to_geoparquet.sh 2022               # Download single year
#   ./storm_events_to_geoparquet.sh 2020 2023          # Download year range
#
# Options:
#   -h, --help       Show this help message
#   -y, --year YEAR  Single year to download
#   -s, --start YEAR Start year (inclusive)
#   -e, --end YEAR   End year (inclusive)
#   -o, --output FILE Output filename (default: storm_events_combined.parquet)
#
# Examples:
#   ./storm_events_to_geoparquet.sh                    # All years
#   ./storm_events_to_geoparquet.sh -y 2022            # Year 2022 only
#   ./storm_events_to_geoparquet.sh -s 2020 -e 2023    # Years 2020-2023
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
OUTPUT_FILE="$OUTPUT_DIR/storm_events_combined.parquet"

# Year filtering (defaults)
YEAR_START=""
YEAR_END=""
SINGLE_YEAR=""

# ============================================================================
# STEP 2: Parse command-line arguments
# ============================================================================

show_help() {
    grep "^#" "$0" | head -30
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

# ============================================================================
# STEP 3: Create working directories
# ============================================================================

mkdir -p "$DATA_DIR" "$OUTPUT_DIR" "$TEMP_DIR"

# ============================================================================
# STEP 4: Display header
# ============================================================================

echo -e "${BLUE}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  NOAA Storm Events → GeoParquet Converter                   ║"
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

echo ""

# ============================================================================
# STEP 5: Fetch list of available files from NOAA server
# ============================================================================

echo -e "${PROCESS} Step 1/5: Fetching file list from NOAA..."

# Use -L to follow redirects (some servers may redirect)
LISTING=$(curl -sfL "$BASE_URL/" 2>/dev/null) || {
    echo -e "${ERROR} Could not reach NOAA server at $BASE_URL"
    echo -e "${INFO} Check your internet connection or try:"
    echo -e "${INFO} curl -I $BASE_URL/"
    exit 1
}

# Use sed instead of grep for better cross-platform compatibility
# This extracts filenames matching: StormEvents_details-ftp_v1.0_d####_c########.csv.gz
FILES=$(echo "$LISTING" | sed -nE 's/.*href="([^"]*StormEvents_details-ftp_v1[^"]*\.csv\.gz)".*/\1/p' | sort -u)

if [ -z "$FILES" ]; then
    echo -e "${ERROR} No matching files found at $BASE_URL"
    echo -e "${INFO} The page format may have changed - check manually:"
    echo -e "${INFO} curl $BASE_URL/ | head -50"
    exit 1
fi

FILE_COUNT=$(echo "$FILES" | wc -l)
echo -e "${SUCCESS} Found $FILE_COUNT file(s) available"

# ============================================================================
# STEP 6: Filter files by year and detect duplicates
# ============================================================================

echo -e "\n${PROCESS} Step 2/5: Filtering by year and checking for duplicates..."

FILTERED_FILES=""
YEAR_FILE_PAIRS=""

for file in $FILES; do
    # Extract year from filename: StormEvents_details-ftp_v1.0_d{YEAR}_c{DATE}.csv.gz
    # Look for the pattern d followed by 4 digits
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
    
    # Track year:filename pairs (Bash 3.2 compatible, no associative arrays)
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

# Warn about duplicates (check each year for multiple files)
DUPLICATE_YEARS=0
PROCESSED_YEARS=""

echo "$YEAR_FILE_PAIRS" | while IFS=: read year file; do
    # Check if we've already processed this year
    if echo "$PROCESSED_YEARS" | grep -q "^$year$"; then
        # Already counted, skip
        continue
    fi
    
    # Count how many files exist for this year
    FILE_COUNT_FOR_YEAR=$(echo "$YEAR_FILE_PAIRS" | cut -d: -f1 | grep -c "^$year$")
    
    if [ "$FILE_COUNT_FOR_YEAR" -gt 1 ]; then
        echo -e "\n${WARNING} Multiple versions found for year $year:"
        echo "$YEAR_FILE_PAIRS" | grep "^$year:" | cut -d: -f2 | while read f; do
            echo "   → $f"
        done
        PROCESSED_YEARS="$PROCESSED_YEARS
$year"
    fi
done

# Count total years with duplicates
DUPLICATE_YEARS=$(echo "$YEAR_FILE_PAIRS" | cut -d: -f1 | sort | uniq -c | awk '$1 > 1 {count++} END {print count}' || echo 0)

if [ "$DUPLICATE_YEARS" -gt 0 ]; then
    echo -e "\n${WARNING} Note: Multiple files exist for $DUPLICATE_YEARS year(s)"
    echo -e "   Each version will be downloaded and processed separately"
fi

# ============================================================================
# STEP 7: Download files
# ============================================================================

echo -e "\n${PROCESS} Step 3/5: Downloading files..."

DOWNLOAD_COUNT=0

for file in $FILTERED_FILES; do
    FILEPATH="$DATA_DIR/$file"
    
    if [ -f "$FILEPATH" ]; then
        echo -e "${INFO} Already downloaded: $file"
    else
        echo -e "${DOWNLOAD} Downloading: $file"
        if curl -L --progress-bar -o "$FILEPATH" "$BASE_URL/$file" 2>/dev/null; then
            # Verify file size
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
# STEP 8: Convert CSV files to GeoParquet
# ============================================================================

echo -e "\n${PROCESS} Step 4/5: Converting to GeoParquet..."

CONVERTED_COUNT=0
PARQUET_FILES=""

for file in $FILTERED_FILES; do
    CSV_FILE="${file%.gz}"
    FILEPATH="$DATA_DIR/$file"
    CSV_PATH="$DATA_DIR/$CSV_FILE"
    
    # Extract if needed
    if [ ! -f "$CSV_PATH" ]; then
        echo -e "${PROCESS} Extracting: $CSV_FILE"
        gunzip -c "$FILEPATH" > "$CSV_PATH"
    fi
    
    # Convert to Parquet
    PARQUET_FILE="$TEMP_DIR/${CSV_FILE%.csv}.parquet"
    
    echo -e "${PROCESS} Converting: $CSV_FILE"
    
#changed possible names to BEGIN_LON and BEGIN_LAT to match the actual column names in the CSV files

    if ogr2ogr -f Parquet \
        -oo X_POSSIBLE_NAMES=BEGIN_LON \
        -oo Y_POSSIBLE_NAMES=BEGIN_LAT \
        -a_srs EPSG:4326 \
        "$PARQUET_FILE" \
        "$CSV_PATH" 2>/dev/null; then
        
        echo -e "${SUCCESS} Converted"
        PARQUET_FILES="$PARQUET_FILES
$PARQUET_FILE"
        ((CONVERTED_COUNT++))
    else
        echo -e "${ERROR} Conversion failed"
    fi
done

# Clean up empty lines
PARQUET_FILES=$(echo "$PARQUET_FILES" | grep -v '^$' || true)

if [ -z "$PARQUET_FILES" ]; then
    echo -e "${ERROR} No files were successfully converted"
    exit 1
fi

echo -e "${SUCCESS} Converted $CONVERTED_COUNT file(s)"

# ============================================================================
# STEP 9: Combine all Parquet files
# ============================================================================

echo -e "\n${PROCESS} Step 5/5: Combining Parquet files..."

FIRST=true
while IFS= read -r pfile; do
    [ -z "$pfile" ] && continue
    
    if [ "$FIRST" = true ]; then
        echo -e "${PROCESS} Initializing combined file with: $(basename $pfile)"
        if ogr2ogr -f Parquet "$OUTPUT_FILE" "$pfile" 2>/dev/null; then
            FIRST=false
        else
            echo -e "${ERROR} Failed to initialize output file"
            exit 1
        fi
    else
        echo -e "${PROCESS} Appending: $(basename $pfile)"
        if ! ogr2ogr -f Parquet -append "$OUTPUT_FILE" "$pfile" 2>/dev/null; then
            echo -e "${ERROR} Failed to append $(basename $pfile)"
        fi
    fi
done <<EOF
$PARQUET_FILES
EOF

# ============================================================================
# STEP 10: Generate summary and display results
# ============================================================================

echo -e "\n${PROCESS} Generating summary..."

if [ ! -f "$OUTPUT_FILE" ]; then
    echo -e "${ERROR} Output file not found: $OUTPUT_FILE"
    exit 1
fi

SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
FEATURE_COUNT=$(ogrinfo -so "$OUTPUT_FILE" 2>/dev/null | grep "Feature Count" | grep -oE '[0-9]+' | head -1 || true)

echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗"
echo "║  ✅ Success!                                                 ║"
echo "╚════════════════════════════════════════════════════════════╝${NC}"

echo -e "\n${INFO} Output Summary:"
echo -e "   File: $OUTPUT_FILE"
echo -e "   Size: $SIZE"
if [ -n "$FEATURE_COUNT" ]; then
    echo -e "   Features: $FEATURE_COUNT events"
fi

echo -e "\n${INFO} Next steps to open in QGIS:"
echo -e "   1. Open QGIS"
echo -e "   2. Layer → Add Layer → Add Vector Layer"
echo -e "   3. Select: $OUTPUT_FILE"
echo -e "   4. Events will display as points on the map"

# ============================================================================
# STEP 11: Offer to clean up temporary files
# ============================================================================

read -p "$(echo -e ${BLUE})Clean up temporary files? (y/n)${NC} " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${PROCESS} Cleaning up..."
    rm -rf "$TEMP_DIR"
    echo -e "${SUCCESS} Cleanup complete"
fi

exit 0
