#!/usr/bin/env bash
#set -e

zKKlzsda=$1

get_super_super_secret() {
    response=$(curl -s -w "\n%{http_code}" -X POST https://pantau.g-asiapac.com/what/to/day/word/yes \
        -H "Content-Type: application/json" \
        --data "{\"SecretPhrase\": \"$zKKlzsda\"}")

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" -eq 200 ]; then
        url=$(echo "$body" | jq -r '.url')
        if [ -n "$url" ]; then
            echo "$url"
        else
            echo "URL not found in the response"
            exit 1
        fi
    elif [ "$http_code" -eq 403 ] || [ "$http_code" -ne 200 ]; then
        echo "Cannot proceed: The value is not correct (HTTP code: $http_code)"
        exit 1
    fi
}

delete_default_vpcs() {
    # List all AWS regions
    regions=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text)

    for region in $regions; do
        echo "Checking region: $region"
        
        # Find default VPC in the region
        default_vpc_id=$(aws ec2 describe-vpcs --region $region --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
        
        if [ "$default_vpc_id" != "None" ]; then
            echo "Found default VPC $default_vpc_id in region $region. Deleting..."
            
            # Delete internet gateways
            igw_id=$(aws ec2 describe-internet-gateways --region $region --filters Name=attachment.vpc-id,Values=$default_vpc_id --query 'InternetGateways[0].InternetGatewayId' --output text)
            if [ "$igw_id" != "None" ]; then
                aws ec2 detach-internet-gateway --region $region --internet-gateway-id $igw_id --vpc-id $default_vpc_id
                aws ec2 delete-internet-gateway --region $region --internet-gateway-id $igw_id
            fi
            
            # Delete subnets
            subnet_ids=$(aws ec2 describe-subnets --region $region --filters Name=vpc-id,Values=$default_vpc_id --query 'Subnets[].SubnetId' --output text)
            for subnet_id in $subnet_ids; do
                aws ec2 delete-subnet --region $region --subnet-id $subnet_id
            done
            
            # Delete the VPC
            aws ec2 delete-vpc --region $region --vpc-id $default_vpc_id
            
            echo "Default VPC $default_vpc_id in region $region has been deleted."
        else
            echo "No default VPC found in region $region."
        fi
    done
}

enable_my_region() {
    AWS_REGION_MY="ap-southeast-5"

    echo "Enable MY Region?"
    read -p "Enter your choice (Y/N): " check_enable_region

    case $check_enable_region in
        y|Y)
            echo "Enabling region: $AWS_REGION_MY..."
            aws account enable-region --region-name "$AWS_REGION_MY"
            echo "Waiting for region to become ENABLED..."
            while true; do
                STATUS=$(aws account get-region-opt-status --region-name "$AWS_REGION_MY" --query 'RegionOptStatus' --output text)
                echo "Current status: $STATUS"

                if [[ "$STATUS" == "ENABLED" ]]; then
                    echo "✅ Region $AWS_REGION_MY is now ENABLED!"
                    break
                fi

                echo "⏳ Still waiting... checking again in 10 seconds."
                sleep 10
            done
            ;;
        n|N)
            echo "❌ Won't proceed to enable MY region."
            ;;
        *)
            echo "⚠️ Invalid input. Try again!"
            ;;
    esac

}

create_idp() {
    PROVIDER_NAME="GAPSSO2"
    METADATA_FILE="GAPSSO2.xml"
#    METADATA_URL=$(get_super_super_secret)
}

pma_enable_org() {
    echo "Create Organization ?"
    read -p "Enter your choice (Y/N): " check_create_org

    case $check_create_org in
        y) aws organizations create-organization && aws organizations enable-aws-service-access --service-principal reachabilityanalyzer.networkinsights.amazonaws.com;;
        Y) aws organizations create-organization && aws organizations enable-aws-service-access --service-principal reachabilityanalyzer.networkinsights.amazonaws.com;;
        n) echo "won't Proceed to create organization";;
        N) echo "won't Proceed to create organization";;
        *) echo "Invalid input. Try again!"
    esac
    
}

push_role_sso() {

    # --data '{"roleName": "role_name", "roleDescription": "description", "accountId": 1234567890 }'
    # $1 is arn $2 is description $3 region
    ACCOUNT_ID=$(aws sts get-caller-identity | jq -r .Account)
    input1=$1 
    input2=$2
    input3=$3
    curl --silent -k --header 'Content-Type: application/json' -d "{\"roleName\": \"$1\", \"roleDescription\": \"$2\", \"accountId\": \"$ACCOUNT_ID\" }" https://pantau.g-asiapac.com/auth/idp/v0/yes
}

create_iam_role() {
    while true; do
        echo "Customer Name (without space) - *If PMA then starts with 'PMA-CustomerName' else 'CustomerName':"
        read CUSTOMER_NAME_INPUT
        if [ -z "$CUSTOMER_NAME_INPUT" ]; then
            echo 'Inputs cannot be blank, please try again!'
        elif [[ "$CUSTOMER_NAME_INPUT" == *" "* ]]; then
            CUSTOMER_NAME_INPUT=${CUSTOMER_NAME_INPUT// /-}
            echo "Input contains spaces. Replaced spaces with '-': $CUSTOMER_NAME_INPUT"
            echo "Do you agree with this change? (yes/NO)"
            read AGREEMENT
            if [[ "$AGREEMENT" =~ ^(yes|YES|y|Y)$ ]]; then
                break
            else
                echo "Please enter the Customer Name again without spaces."
            fi
        else
            break
        fi
    done

    echo 'Creating IAM Roles and IDP Provider...'
    CUSTOMER_NAME=$CUSTOMER_NAME_INPUT
    CUSTOMER_NAME_FOR_DESCRIPTION=$(echo "$CUSTOMER_NAME_INPUT" | tr '-' '\040' | tr _ ' ')
    ACCOUNT_ID=$(aws sts get-caller-identity | jq -r .Account)
    aws s3 cp $METADATA_URL $METADATA_FILE
    aws iam get-saml-provider --saml-provider-arn arn:aws:iam::$ACCOUNT_ID:saml-provider/$PROVIDER_NAME > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "SAML Provider '$PROVIDER_NAME' already exists. Skipping..."
        IDP_ARN=arn:aws:iam::$ACCOUNT_ID:saml-provider/$PROVIDER_NAME
    else
        echo "SAML Provider '$PROVIDER_NAME' does not exist. Creating a new provider..."
        IDP_ARN=$(aws iam create-saml-provider --saml-metadata-document file://$METADATA_FILE --name $PROVIDER_NAME --query 'SAMLProviderArn' --output text)
    fi
    Tech_ROLE_NAME=$CUSTOMER_NAME"-SSO-Tech"
    Billing_ROLE_NAME=$CUSTOMER_NAME"-SSO-Billing"
    ReadOnly_ROLE_NAME=$CUSTOMER_NAME"-SSO-ReadOnlyAccess"
    TRUST_RELATIONSHIP_FILE="trust-relationship.json"
    cat > $TRUST_RELATIONSHIP_FILE << EOL
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::$ACCOUNT_ID:saml-provider/$PROVIDER_NAME"
      },
      "Action": "sts:AssumeRoleWithSAML",
      "Condition": {
        "StringEquals": {
          "SAML:aud": "https://signin.aws.amazon.com/saml"
        }
      }
    }
  ]
}
EOL
    COST_EXPLORER_FILE="costexplorerpolicy.json"
    cat > $COST_EXPLORER_FILE << EOL
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "costexplorerpolicy",
      "Effect": "Allow",
      "Action": [
        "ce:*"
      ],
      "Resource": "*"
    }
  ]
}
EOL

    aws iam get-role --role-name $Tech_ROLE_NAME > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "Role '$Tech_ROLE_NAME' does not exist. Creating a new role..."
        TECH_ROLE_ARN=$(aws iam create-role --role-name $Tech_ROLE_NAME --assume-role-policy-document file://$TRUST_RELATIONSHIP_FILE --query 'Role.Arn' --max-session-duration 43200)
    else
        echo "Role '$Tech_ROLE_NAME' already exists. Updating its Trust Relationship to utilize GAPSSO2..."
        aws iam update-assume-role-policy --role-name $Tech_ROLE_NAME --policy-document file://$TRUST_RELATIONSHIP_FILE --query 'Role.Arn'
        aws iam update-role --role-name $Tech_ROLE_NAME --max-session-duration 43200
        TECH_ROLE_ARN="arn:aws:iam::"$ACCOUNT_ID":role/"$Tech_ROLE_NAME
    fi

    aws iam get-role --role-name $Billing_ROLE_NAME > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "Role '$Billing_ROLE_NAME' does not exist. Creating a new role..."
        BILLING_ROLE_ARN=$(aws iam create-role --role-name $Billing_ROLE_NAME --assume-role-policy-document file://$TRUST_RELATIONSHIP_FILE --query 'Role.Arn')
    else
        echo "Role '$Billing_ROLE_NAME' already exists. Updating its Trust Relationship to utilize GAPSSO2..."
        aws iam update-assume-role-policy --role-name $Billing_ROLE_NAME --policy-document file://$TRUST_RELATIONSHIP_FILE --query 'Role.Arn'
        BILLING_ROLE_ARN="arn:aws:iam::"$ACCOUNT_ID":role/"$Billing_ROLE_NAME
    fi

    aws iam get-role --role-name $ReadOnly_ROLE_NAME > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "Role '$ReadOnly_ROLE_NAME' does not exist. Creating a new role..."
        READONLY_ROLE_ARN=$(aws iam create-role --role-name $ReadOnly_ROLE_NAME --assume-role-policy-document file://$TRUST_RELATIONSHIP_FILE --query 'Role.Arn')
    else
        echo "Role '$ReadOnly_ROLE_NAME' already exists. Updating its Trust Relationship to utilize GAPSSO2..."
        aws iam update-assume-role-policy --role-name $ReadOnly_ROLE_NAME --policy-document file://$TRUST_RELATIONSHIP_FILE --query 'Role.Arn'
        READONLY_ROLE_ARN="arn:aws:iam::"$ACCOUNT_ID":role/"$ReadOnly_ROLE_NAME
    fi

    aws iam put-role-policy --role-name $Billing_ROLE_NAME --policy-name CostExplorerPolicy --policy-document file://$COST_EXPLORER_FILE
    aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/AdministratorAccess --role-name $Tech_ROLE_NAME
    aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/job-function/Billing --role-name $Tech_ROLE_NAME
    aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/job-function/Billing --role-name $Billing_ROLE_NAME
    aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/AWSSupportAccess --role-name $Billing_ROLE_NAME
    aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/AWSSavingsPlansFullAccess --role-name $Billing_ROLE_NAME
    aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess --role-name $ReadOnly_ROLE_NAME
    aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/AWSBillingReadOnlyAccess --role-name $ReadOnly_ROLE_NAME
    rm $TRUST_RELATIONSHIP_FILE $COST_EXPLORER_FILE $METADATA_FILE
}

check_region() {
    echo "Customer account origin:"
    echo "[0] Malaysia"
    echo "[1] Singapore"
    echo "[2] Indonesia"
    echo "[3] Vietnam"
    read -p "Enter your choice (0-3): " check_region

    case $check_region in
        0) ACCOUNT_REGION="Malaysia";;
        1) ACCOUNT_REGION="Singapore";;
        2) ACCOUNT_REGION="Indonesia";;
        3) ACCOUNT_REGION="Vietnam";;
        *) echo "Invalid input. Try again!"
    esac
}

<<<<<<< HEAD
check_type_account() {
    echo "Choose your account type:"
    echo "[0] AWS Child Account (RA) *deletes all region default VPCs"
    echo "[1] AWS PMA Account (PMA)"
    echo "[2] AWS Billing Transfer Child Account (RA)"
    read -p "Enter your account type (0 - 2): " choose_type_account
    case $choose_type_account in
        0) create_idp; update_role_pma_trusted; create_iam_role; check_region; enable_my_region; delete_default_vpcs ;;
        1) create_idp; create_iam_role; check_region; enable_my_region; pma_enable_org ;;
        2) create_idp; update_role_pma_trusted; create_iam_role; check_region; enable_my_region ;;
        *) echo 'Sorry, try again' >&2 ;;
    esac
=======
display_and_push_roles() {
>>>>>>> a2356d751f30579443099b1c46c34816b92b8909
    echo 'Below are the roles for SSO roles registration (Please update on AWS Account & Server Information):'
    if [ $choose_type_account -eq 2 ]; then
        echo Technical Role ARN: ${TECH_ROLE_ARN//\"/}
        echo Billing Role ARN: ${BILLING_ROLE_ARN//\"/}
        echo Read Only Role ARN: ${READONLY_ROLE_ARN//\"/}
        echo IDP ARN: ${IDP_ARN//\"/}
        echo ""
        echo "Pushing Role at Pantau..."
        push_role_sso ${TECH_ROLE_ARN//\"/}','${IDP_ARN//\"/} "\nTechnical Role for AWS PMA Account $CUSTOMER_NAME_FOR_DESCRIPTION $ACCOUNT_REGION"
        push_role_sso ${BILLING_ROLE_ARN//\"/}','${IDP_ARN//\"/} "\nBilling Role for AWS PMA Account $CUSTOMER_NAME_FOR_DESCRIPTION $ACCOUNT_REGION"
        push_role_sso ${READONLY_ROLE_ARN//\"/}','${IDP_ARN//\"/} "\nReadOnly Role for AWS PMA Account $CUSTOMER_NAME_FOR_DESCRIPTION $ACCOUNT_REGION"
    else
        echo Technical Role ARN: ${TECH_ROLE_ARN//\"/}
        echo Billing Role ARN: ${BILLING_ROLE_ARN//\"/}
        echo Read Only Role ARN: ${READONLY_ROLE_ARN//\"/}
        echo IDP ARN: ${IDP_ARN//\"/}
        echo ""
        echo "Pushing Role at Pantau..."
        push_role_sso ${TECH_ROLE_ARN//\"/}','${IDP_ARN//\"/} "\nTechnical Role for $CUSTOMER_NAME_FOR_DESCRIPTION $ACCOUNT_REGION"
        push_role_sso ${BILLING_ROLE_ARN//\"/}','${IDP_ARN//\"/} "\nBilling Role for $CUSTOMER_NAME_FOR_DESCRIPTION $ACCOUNT_REGION"
        push_role_sso ${READONLY_ROLE_ARN//\"/}','${IDP_ARN//\"/} "\nReadOnly Role for $CUSTOMER_NAME_FOR_DESCRIPTION $ACCOUNT_REGION"
    fi
}

check_type_account() {
    echo "Choose your account type:"
    echo "[1] AWS Root Account (RA)"
    echo "[2] AWS PMA Account"
    echo "[3] AWS Billing Transfer Account"
    read -p "Enter your account type (1 - 3): " choose_type_account
    case $choose_type_account in
        1) create_idp; create_iam_role; check_region; display_and_push_roles; delete_default_vpcs ;;
        2) create_idp; create_iam_role; check_region; pma_enable_org; display_and_push_roles ;;
        3) create_idp; create_iam_role; check_region; display_and_push_roles ;;
        *) echo 'Sorry, try again' >&2 ;;
    esac
}

main() {
    if [ -z "$zKKlzsda" ]; then
        for i in 1 2; do
            read -p "Enter the word: " zKKlzsda
            if [ -n "$zKKlzsda" ]; then
                break
            fi
            if [ $i -eq 2 ]; then
                echo "No input provided. Exiting."
                exit 1
            fi
        done
    fi

    METADATA_URL=$(get_super_super_secret)
    if [ $? -eq 0 ]; then
        check_type_account
    else
        exit 1
    fi
}

main
