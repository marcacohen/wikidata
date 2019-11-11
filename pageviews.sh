#!/usr/bin/env bash

# Copyright 2019 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eEuo pipefail

if [ -z ${K_SERVICE+x} ]
then
  EOL="\n"
else
  EOL="\r\n"
fi
USAGE="$0 [all|year|month|day]"
WINDOW="${1:-day}"
PROJECT=bigquery-public-data-staging
BUCKET=wiki-staging
DOMAIN=dumps.wikimedia.org
SRC_BASE=https://$DOMAIN
DST_BASE=gs://$BUCKET
SRC_VIEW_PATH=other/pageviews
DST_VIEW_PATH=$DOMAIN/$SRC_VIEW_PATH
SRC_VIEW_URL=$SRC_BASE/$SRC_VIEW_PATH
DST_VIEW_URL=$DST_BASE/$DST_VIEW_PATH

HEAD="$(cat <<EOF
HTTP/1.1 200 OK
Connection: keep-alive\r\n\r\n
EOF
)"

TODAY=$(date '+%s')
YYYY=$(date --date=@$TODAY +%Y)
MM=$(date --date=@$TODAY +%m)
DD=$(date --date=@$TODAY +%d)

if [ "$WINDOW" = "all" ]
then
  S1=/; S2=*/*/ S3=pageviews-*.gz
elif [ "$WINDOW" = "year" ]
then
  S1=/$YYYY/; S2=*/; S3=pageviews-$YYYY*.gz
elif [ "$WINDOW" = "month" ]
then 
  S1=/$YYYY/$YYYY-$MM/; S2=; S3=pageviews-$YYYY$MM*.gz
elif [ "$WINDOW" = "day" ]
then 
  S1=/$YYYY/$YYYY-$MM/; S2=; S3=pageviews-$YYYY$MM$DD-*.gz
fi

if [ ! -z ${K_SERVICE+x} ]
then
  echo -en "$HEAD" 
fi

# Assemble list of every pageview log file and size on website.
wget --no-parent -nv --spider -S -r -A "$S3" $SRC_VIEW_URL$S1 2>&1 |
awk 'function base(file, a, n) {n = split(file,a,"/"); return a[n]} \
     $1 == "Content-Length:" {len=$2} $3 == "URL:" {print base($4), len}' |
sort >src-files.txt

# Assemble list of every pageview log file and size in cloud storage.
>dst-files.txt
if gsutil stat $DST_VIEW_URL$S1$S2$S3 >/dev/null 2>&1
then
  gsutil ls -l -r $DST_VIEW_URL$S1$S2$S3 2>/dev/null | grep -v ":$" |
  awk 'function base(file, a, n) {n = split(file,a,"/"); return a[n]} \
       $1 != "TOTAL:" {print base($3), $1}' |
  sort >dst-files.txt
fi

# Setup auth for gsutil uploads.
gcloud auth activate-service-account --key-file=key.json
gcloud config set project $PROJECT
gcloud config set account 598876566128-compute@developer.gserviceaccount.com

# One-sided diff - every file that doesn't exist or match size in cloud storage.
comm -23 src-files.txt dst-files.txt |
while read FILE SIZE
do
  DIR=`echo $FILE | awk '{y=substr($1,11,4);m=substr($1,15,2); printf("%s/%s-%s",y,y,m)}'`
  echo -en "$SRC_VIEW_URL/$DIR/$FILE$EOL"
  wget $SRC_VIEW_URL/$DIR/$FILE
  gsutil cp $FILE $DST_VIEW_URL/$DIR/$FILE
  rm $FILE
done

rm src-files.txt dst-files.txt
