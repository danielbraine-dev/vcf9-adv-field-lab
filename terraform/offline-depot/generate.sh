#!/bin/bash

CLIENT_ID=7SxxUEoYtKYpRerCi6U0d3QWMFSa485UkbvorpRlO46h4fde
CLIENT_SECRET=PuW6Esb1qYRqcN92RAwzpqvRPteeIy5UNuR1ywE4oy09b4LQ4ijN4nHmY8TJbQaG
#USER_EMAIL="nathan.thaler@broadcom.com"
USER_EMAIL="svc.config-infra@broadcom.com"

ACCESS_TOKEN=`curl --silent --location 'https://eapi-gcpstg.broadcom.com/auth/oauth/v2/token' \
--header 'Content-Type: application/x-www-form-urlencoded' \
--data-urlencode "client_id=$CLIENT_ID" \
--data-urlencode "client_secret=$CLIENT_SECRET" \
--data-urlencode "grant_type=client_credentials" | jq '.access_token' | sed s/\"//g`

curl --silent --location --request POST "https://eapi-gcpstg.broadcom.com/postg/internaltools/downloads-token/generate-token-internal?userEmail=$USER_EMAIL" \
--header "Authorization: Bearer $ACCESS_TOKEN" | jq '.data.token'
