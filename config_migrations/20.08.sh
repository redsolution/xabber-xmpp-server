#!/bin/bash
echo "Try to modify config " $1
if [ -f $1 ]; then
fileserver=$(grep mod_http_fileserver $1 | tail -n 1 )
vcard=$(grep mod_groupchat_vcard $1 | tail -n 1 )
  if [ "$vcard" != "" ]; then
    echo "mod_groupchat_vcard is already enabled - skipping"
  else
    echo "Adding mod_groupchat_vcard to config"
    get_url=$(grep get_url $1 | tail -n 1 | awk '{print $2}')
    mod_num=$(awk '/modules/{ print NR; exit }' $1)
    sed -i "$mod_num a \  mod_groupchat_vcard:" $1
    sed -i "/mod_groupchat_vcard:/a \    get_url: $get_url" $1 
  fi
  if [ "$fileserver" != "" ]; then
   echo "mod_http_fileserver is already enabled - skipping"
  else
    echo "Adding mod_http_fileserver to config"
    mod_num1=$(awk '/modules/{ print NR; exit }' $1)
    sed -i "$mod_num1 a \  mod_http_fileserver:" $1
    docroot=$(grep docroot $1 | tail -n 1 | awk '{print $2}')
    accesslog="$2/access.log"
    sed -i "/mod_http_fileserver:/a \    docroot: $docroot\n\    accesslog: \"$accesslog\"" $1
    sed -i '/request_handlers/a \      "/images": mod_http_fileserver' $1
  fi
fi
