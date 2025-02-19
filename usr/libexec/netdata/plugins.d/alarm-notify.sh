#!/usr/bin/env bash
#shellcheck source=/dev/null disable=SC2086,SC2154

# netdata
# real-time performance and health monitoring, done right!
# (C) 2017 Costa Tsaousis <costa@tsaousis.gr>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Script to send alarm notifications for netdata
#
# Features:
#  - multiple notification methods
#  - multiple roles per alarm
#  - multiple recipients per role
#  - severity filtering per recipient
#
# Supported notification methods:
#  - emails by @ktsaou
#  - slack.com notifications by @ktsaou
#  - alerta.io notifications by @kattunga
#  - discordapp.com notifications by @lowfive
#  - pushover.net notifications by @ktsaou
#  - pushbullet.com push notifications by Tiago Peralta @tperalta82 #1070
#  - telegram.org notifications by @hashworks #1002
#  - twilio.com notifications by Levi Blaney @shadycuz #1211
#  - kafka notifications by @ktsaou #1342
#  - pagerduty.com notifications by Jim Cooley @jimcooley #1373
#  - messagebird.com notifications by @tech_no_logical #1453
#  - hipchat notifications by @ktsaou #1561
#  - fleep notifications by @Ferroin
#  - prowlapp.com notifications by @Ferroin
#  - custom notifications by @ktsaou
#  - syslog messages by @Ferroin
#  - Microsoft Team notification by @tioumen
#  - RocketChat notifications by @Hermsi1337 #3777

# -----------------------------------------------------------------------------
# testing notifications

if { [ "${1}" = "test" ] || [ "${2}" = "test" ]; } && [ "${#}" -le 2 ]; then
	if [ "${2}" = "test" ]; then
		recipient="${1}"
	else
		recipient="${2}"
	fi

	[ -z "${recipient}" ] && recipient="sysadmin"

	id=1
	last="CLEAR"
	test_res=0
	for x in "WARNING" "CRITICAL" "CLEAR"; do
		echo >&2
		echo >&2 "# SENDING TEST ${x} ALARM TO ROLE: ${recipient}"

		"${0}" "${recipient}" "$(hostname)" 1 1 "${id}" "$(date +%s)" "test_alarm" "test.chart" "test.family" "${x}" "${last}" 100 90 "${0}" 1 $((0 + id)) "units" "this is a test alarm to verify notifications work" "new value" "old value" "evaluated expression" "expression variable values" 0 0
		#shellcheck disable=SC2181
		if [ $? -ne 0 ]; then
			echo >&2 "# FAILED"
			test_res=1
		else
			echo >&2 "# OK"
		fi

		last="${x}"
		id=$((id + 1))
	done

	exit $test_res
fi

export PATH="${PATH}:/sbin:/usr/sbin:/usr/local/sbin"
export LC_ALL=C

# -----------------------------------------------------------------------------

PROGRAM_NAME="$(basename "${0}")"

logdate() {
	date "+%Y-%m-%d %H:%M:%S"
}

log() {
	local status="${1}"
	shift

	echo >&2 "$(logdate): ${PROGRAM_NAME}: ${status}: ${*}"

}

warning() {
	log WARNING "${@}"
}

error() {
	log ERROR "${@}"
}

info() {
	log INFO "${@}"
}

fatal() {
	log FATAL "${@}"
	exit 1
}

debug=${NETDATA_ALARM_NOTIFY_DEBUG-0}
debug() {
	[ "${debug}" = "1" ] && log DEBUG "${@}"
}

docurl() {
	if [ -z "${curl}" ]; then
		error "${curl} is unset."
		return 1
	fi

	if [ "${debug}" = "1" ]; then
		echo >&2 "--- BEGIN curl command ---"
		printf >&2 "%q " ${curl} "${@}"
		echo >&2
		echo >&2 "--- END curl command ---"

		local out code ret
		out=$(mktemp /tmp/netdata-health-alarm-notify-XXXXXXXX)
		code=$(${curl} ${curl_options} --write-out "%{http_code}" --output "${out}" --silent --show-error "${@}")
		ret=$?
		echo >&2 "--- BEGIN received response ---"
		cat >&2 "${out}"
		echo >&2
		echo >&2 "--- END received response ---"
		echo >&2 "RECEIVED HTTP RESPONSE CODE: ${code}"
		rm "${out}"
		echo "${code}"
		return ${ret}
	fi

	${curl} ${curl_options} --write-out "%{http_code}" --output /dev/null --silent --show-error "${@}"
	return $?
}

# -----------------------------------------------------------------------------
# List of all the notification mechanisms we support.
# Used in a couple of places to write more compact code.

method_names="
email
pushover
pushbullet
telegram
slack
alerta
flock
discord
hipchat
twilio
messagebird
pd
fleep
syslog
custom
msteam
kavenegar
prowl
awssns
rocketchat
sms
"

# -----------------------------------------------------------------------------
# this is to be overwritten by the config file

custom_sender() {
	info "not sending custom notification for ${status} of '${host}.${chart}.${name}'"
}

# -----------------------------------------------------------------------------

# check for BASH v4+ (required for associative arrays)
if [ ${BASH_VERSINFO[0]} -lt 4 ]; then
	fatal "BASH version 4 or later is required (this is ${BASH_VERSION})."
fi

# -----------------------------------------------------------------------------
# defaults to allow running this script by hand

[ -z "${NETDATA_USER_CONFIG_DIR}" ] && NETDATA_USER_CONFIG_DIR="/etc/netdata"
[ -z "${NETDATA_STOCK_CONFIG_DIR}" ] && NETDATA_STOCK_CONFIG_DIR="/usr/lib/netdata/conf.d"
[ -z "${NETDATA_CACHE_DIR}" ] && NETDATA_CACHE_DIR="/var/cache/netdata"
[ -z "${NETDATA_REGISTRY_URL}" ] && NETDATA_REGISTRY_URL="https://registry.my-netdata.io"
[ -z "${NETDATA_REGISTRY_CLOUD_BASE_URL}" ] && NETDATA_REGISTRY_CLOUD_BASE_URL="https://netdata.cloud"

# -----------------------------------------------------------------------------
# parse command line parameters

if [ ${1} = "unittest" ]; then
	unittest=1        # enable unit testing mode
	roles="${2}"      # the role that should be used for unit testing
	cfgfile="${3}"    # the location of the config file to use for unit testing
	status="${4}"     # the current status : REMOVED, UNINITIALIZED, UNDEFINED, CLEAR, WARNING, CRITICAL
	old_status="${5}" # the previous status: REMOVED, UNINITIALIZED, UNDEFINED, CLEAR, WARNING, CRITICAL
else
	roles="${1}"               # the roles that should be notified for this event
	args_host="${2}"           # the host generated this event
	unique_id="${3}"           # the unique id of this event
	alarm_id="${4}"            # the unique id of the alarm that generated this event
	event_id="${5}"            # the incremental id of the event, for this alarm id
	when="${6}"                # the timestamp this event occurred
	name="${7}"                # the name of the alarm, as given in netdata health.d entries
	chart="${8}"               # the name of the chart (type.id)
	family="${9}"              # the family of the chart
	status="${10}"             # the current status : REMOVED, UNINITIALIZED, UNDEFINED, CLEAR, WARNING, CRITICAL
	old_status="${11}"         # the previous status: REMOVED, UNINITIALIZED, UNDEFINED, CLEAR, WARNING, CRITICAL
	value="${12}"              # the current value of the alarm
	old_value="${13}"          # the previous value of the alarm
	src="${14}"                # the line number and file the alarm has been configured
	duration="${15}"           # the duration in seconds of the previous alarm state
	non_clear_duration="${16}" # the total duration in seconds this is/was non-clear
	units="${17}"              # the units of the value
	info="${18}"               # a short description of the alarm
	value_string="${19}"       # friendly value (with units)
	# shellcheck disable=SC2034
	# variable is unused, but https://github.com/netdata/netdata/pull/5164#discussion_r255572947
	old_value_string="${20}"   # friendly old value (with units), previously named "old_value_string"
	calc_expression="${21}"    # contains the expression that was evaluated to trigger the alarm
	calc_param_values="${22}"  # the values of the parameters in the expression, at the time of the evaluation
	total_warnings="${23}"     # Total number of alarms in WARNING state
	total_critical="${24}"     # Total number of alarms in CRITICAL state
fi

# -----------------------------------------------------------------------------
# find a suitable hostname to use, if netdata did not supply a hostname

if [ -z ${args_host} ]; then
	this_host=$(hostname -s 2>/dev/null)
	host="${this_host}"
	args_host="${this_host}"
else
	host="${args_host}"
fi

# -----------------------------------------------------------------------------
# screen statuses we don't need to send a notification

# don't do anything if this is not WARNING, CRITICAL or CLEAR
if [ "${status}" != "WARNING" ] && [ "${status}" != "CRITICAL" ] && [ "${status}" != "CLEAR" ]; then
	info "not sending notification for ${status} of '${host}.${chart}.${name}'"
	exit 1
fi

# don't do anything if this is CLEAR, but it was not WARNING or CRITICAL
if [ "${clear_alarm_always}" != "YES" ] && [ "${old_status}" != "WARNING" ] && [ "${old_status}" != "CRITICAL" ] && [ "${status}" = "CLEAR" ]; then
	info "not sending notification for ${status} of '${host}.${chart}.${name}' (last status was ${old_status})"
	exit 1
fi

# -----------------------------------------------------------------------------
# load configuration

# By default fetch images from the global public registry.
# This is required by default, since all notification methods need to download
# images via the Internet, and private registries might not be reachable.
# This can be overwritten at the configuration file.
images_base_url="https://registry.my-netdata.io"

# curl options to use
curl_options=""

# hostname handling
use_fqdn="NO"

# needed commands
# if empty they will be searched in the system path
curl=
sendmail=

# enable / disable features
for method_name in ${method_names^^}; do
	declare SEND_${method_name}="YES"
	declare DEFAULT_RECIPIENT_${method_name}
done

for method_name in ${method_names}; do
	declare -A role_recipients_${method_name}
done

# slack configs
SLACK_WEBHOOK_URL=

# Microsoft Team configs
MSTEAM_WEBHOOK_URL=

# rocketchat configs
ROCKETCHAT_WEBHOOK_URL=

# alerta configs
ALERTA_WEBHOOK_URL=
ALERTA_API_KEY=

# flock configs
FLOCK_WEBHOOK_URL=

# discord configs
DISCORD_WEBHOOK_URL=

# pushover configs
PUSHOVER_APP_TOKEN=

# pushbullet configs
PUSHBULLET_ACCESS_TOKEN=
PUSHBULLET_SOURCE_DEVICE=

# twilio configs
TWILIO_ACCOUNT_SID=
TWILIO_ACCOUNT_TOKEN=
TWILIO_NUMBER=

# hipchat configs
HIPCHAT_SERVER=
HIPCHAT_AUTH_TOKEN=

# messagebird configs
MESSAGEBIRD_ACCESS_KEY=
MESSAGEBIRD_NUMBER=

# kavenegar configs
KAVENEGAR_API_KEY=
KAVENEGAR_SENDER=

# telegram configs
TELEGRAM_BOT_TOKEN=

# kafka configs
SEND_KAFKA="YES"
KAFKA_URL=
KAFKA_SENDER_IP=

# pagerduty.com configs
PD_SERVICE_KEY=

# fleep.io configs
FLEEP_SENDER="${host}"

# Amazon SNS configs
AWSSNS_MESSAGE_FORMAT=

# syslog configs
SYSLOG_FACILITY=

# email configs
EMAIL_SENDER=
EMAIL_CHARSET=$(locale charmap 2>/dev/null)
EMAIL_THREADING=
EMAIL_PLAINTEXT_ONLY=

# irc configs
IRC_NICKNAME=
IRC_REALNAME=
IRC_NETWORK=

# load the stock and user configuration files
# these will overwrite the variables above

if [ ${unittest} ]; then
	if source "${cfgfile}"; then
		error "Failed to load requested config file."
		exit 1
	fi
else
	for CONFIG in "${NETDATA_STOCK_CONFIG_DIR}/health_alarm_notify.conf" "${NETDATA_USER_CONFIG_DIR}/health_alarm_notify.conf"; do
		if [ -f "${CONFIG}" ]; then
			debug "Loading config file '${CONFIG}'..."
			source "${CONFIG}" || error "Failed to load config file '${CONFIG}'."
		else
			warning "Cannot find file '${CONFIG}'."
		fi
	done
fi

# If we didn't autodetect the character set for e-mail and it wasn't
# set by the user, we need to set it to a reasonable default.  UTF-8
# should be correct for almost all modern UNIX systems.
if [ -z ${EMAIL_CHARSET} ]; then
	EMAIL_CHARSET="UTF-8"
fi

# If we've been asked to use FQDN's for the URL's in the alarm, do so,
# unless we're sending an alarm for a slave system which we can't get the
# FQDN of easily.
if [ "${use_fqdn}" = "YES" ] && [ "${host}" = "$(hostname -s 2>/dev/null)" ]; then
	host="$(hostname -f 2>/dev/null)"
fi

# -----------------------------------------------------------------------------
# filter a recipient based on alarm event severity

filter_recipient_by_criticality() {
	local method="${1}" x="${2}" r s
	shift

	r="${x/|*/}" # the recipient
	s="${x/*|/}" # the severity required for notifying this recipient

	# no severity filtering for this person
	[ "${r}" = "${s}" ] && return 0

	# the severity is invalid
	s="${s^^}"
	if [ "${s}" != "CRITICAL" ]; then
		error "SEVERITY FILTERING for ${x} VIA ${method}: invalid severity '${s,,}', only 'critical' is supported."
		return 0
	fi

	# create the status tracking directory for this user
	[ ! -d "${NETDATA_CACHE_DIR}/alarm-notify/${method}/${r}" ] &&
		mkdir -p "${NETDATA_CACHE_DIR}/alarm-notify/${method}/${r}"

	case "${status}" in
	CRITICAL)
		# make sure he will get future notifications for this alarm too
		touch "${NETDATA_CACHE_DIR}/alarm-notify/${method}/${r}/${alarm_id}"
		debug "SEVERITY FILTERING for ${x} VIA ${method}: ALLOW: the alarm is CRITICAL (will now receive next status change)"
		return 0
		;;

	WARNING)
		if [ -f "${NETDATA_CACHE_DIR}/alarm-notify/${method}/${r}/${alarm_id}" ]; then
			# we do not remove the file, so that he will get future notifications of this alarm
			debug "SEVERITY FILTERING for ${x} VIA ${method}: ALLOW: recipient has been notified for this alarm in the past (will still receive next status change)"
			return 0
		fi
		;;

	*)
		if [ -f "${NETDATA_CACHE_DIR}/alarm-notify/${method}/${r}/${alarm_id}" ]; then
			# remove the file, so that he will only receive notifications for CRITICAL states for this alarm
			rm "${NETDATA_CACHE_DIR}/alarm-notify/${method}/${r}/${alarm_id}"
			debug "SEVERITY FILTERING for ${x} VIA ${method}: ALLOW: recipient has been notified for this alarm (will only receive CRITICAL notifications from now on)"
			return 0
		fi
		;;
	esac

	debug "SEVERITY FILTERING for ${x} VIA ${method}: BLOCK: recipient should not receive this notification"
	return 1
}

# -----------------------------------------------------------------------------
# verify the delivery methods supported

# check slack
[ -z "${SLACK_WEBHOOK_URL}" ] && SEND_SLACK="NO"

# check rocketchat
[ -z "${ROCKETCHAT_WEBHOOK_URL}" ] && SEND_ROCKETCHAT="NO"

# check alerta
[ -z "${ALERTA_WEBHOOK_URL}" ] && SEND_ALERTA="NO"

# check flock
[ -z "${FLOCK_WEBHOOK_URL}" ] && SEND_FLOCK="NO"

# check discord
[ -z "${DISCORD_WEBHOOK_URL}" ] && SEND_DISCORD="NO"

# check pushover
[ -z "${PUSHOVER_APP_TOKEN}" ] && SEND_PUSHOVER="NO"

# check pushbullet
[ -z "${PUSHBULLET_ACCESS_TOKEN}" ] && SEND_PUSHBULLET="NO"

# check twilio
{ [ -z "${TWILIO_ACCOUNT_TOKEN}" ] || [ -z "${TWILIO_ACCOUNT_SID}" ] || [ -z "${TWILIO_NUMBER}" ]; } && SEND_TWILIO="NO"

# check hipchat
[ -z "${HIPCHAT_AUTH_TOKEN}" ] && SEND_HIPCHAT="NO"

# check messagebird
{ [ -z "${MESSAGEBIRD_ACCESS_KEY}" ] || [ -z "${MESSAGEBIRD_NUMBER}" ]; } && SEND_MESSAGEBIRD="NO"

# check kavenegar
{ [ -z "${KAVENEGAR_API_KEY}" ] || [ -z "${KAVENEGAR_SENDER}" ]; } && SEND_KAVENEGAR="NO"

# check telegram
[ -z "${TELEGRAM_BOT_TOKEN}" ] && SEND_TELEGRAM="NO"

# check kafka
{ [ -z "${KAFKA_URL}" ] || [ -z "${KAFKA_SENDER_IP}" ]; } && SEND_KAFKA="NO"

# check irc
[ -z "${IRC_NETWORK}" ] && SEND_IRC="NO"

# check fleep
#shellcheck disable=SC2153
{ [ -z "${FLEEP_SERVER}" ] || [ -z "${FLEEP_SENDER}" ]; } && SEND_FLEEP="NO"

if [ "${SEND_PUSHOVER}" = "YES" ] ||
	[ "${SEND_SLACK}" = "YES" ] ||
	[ "${SEND_ROCKETCHAT}" = "YES" ] ||
	[ "${SEND_ALERTA}" = "YES" ] ||
	[ "${SEND_PD}" = "YES" ] ||
	[ "${SEND_FLOCK}" = "YES" ] ||
	[ "${SEND_DISCORD}" = "YES" ] ||
	[ "${SEND_HIPCHAT}" = "YES" ] ||
	[ "${SEND_TWILIO}" = "YES" ] ||
	[ "${SEND_MESSAGEBIRD}" = "YES" ] ||
	[ "${SEND_KAVENEGAR}" = "YES" ] ||
	[ "${SEND_TELEGRAM}" = "YES" ] ||
	[ "${SEND_PUSHBULLET}" = "YES" ] ||
	[ "${SEND_KAFKA}" = "YES" ] ||
	[ "${SEND_FLEEP}" = "YES" ] ||
	[ "${SEND_PROWL}" = "YES" ] ||
	[ "${SEND_CUSTOM}" = "YES" ] ||
	[ "${SEND_MSTEAM}" = "YES" ]; then
	# if we need curl, check for the curl command
	if [ -z "${curl}" ]; then
		curl="$(command -v curl 2>/dev/null)"
	fi
	if [ -z "${curl}" ]; then
		error "Cannot find curl command in the system path. Disabling all curl based notifications."
		SEND_PUSHOVER="NO"
		SEND_PUSHBULLET="NO"
		SEND_TELEGRAM="NO"
		SEND_SLACK="NO"
		SEND_MSTEAM="NO"
		SEND_ROCKETCHAT="NO"
		SEND_ALERTA="NO"
		SEND_PD="NO"
		SEND_FLOCK="NO"
		SEND_DISCORD="NO"
		SEND_TWILIO="NO"
		SEND_HIPCHAT="NO"
		SEND_MESSAGEBIRD="NO"
		SEND_KAVENEGAR="NO"
		SEND_KAFKA="NO"
		SEND_FLEEP="NO"
		SEND_PROWL="NO"
		SEND_CUSTOM="NO"
	fi
fi

if [ "${SEND_SMS}" = "YES" ]; then
	if [ -z "${sendsms}" ]; then
		sendsms="$(command -v sendsms 2>/dev/null)"
	fi
	if [ -z "${sendsms}" ]; then
		SEND_SMS="NO"
	fi
fi
# if we need sendmail, check for the sendmail command
if [ "${SEND_EMAIL}" = "YES" ] && [ -z "${sendmail}" ]; then
	sendmail="$(command -v sendmail 2>/dev/null)"
	if [ -z "${sendmail}" ]; then
		debug "Cannot find sendmail command in the system path. Disabling email notifications."
		SEND_EMAIL="NO"
	fi
fi

# if we need logger, check for the logger command
if [ "${SEND_SYSLOG}" = "YES" ] && [ -z "${logger}" ]; then
	logger="$(command -v logger 2>/dev/null)"
	if [ -z "${logger}" ]; then
		debug "Cannot find logger command in the system path. Disabling syslog notifications."
		SEND_SYSLOG="NO"
	fi
fi

# if we need aws, check for the aws command
if [ "${SEND_AWSSNS}" = "YES" ] && [ -z "${aws}" ]; then
	aws="$(command -v aws 2>/dev/null)"
	if [ -z "${aws}" ]; then
		debug "Cannot find aws command in the system path.  Disabling Amazon SNS notifications."
		SEND_AWSSNS="NO"
	fi
fi

# -----------------------------------------------------------------------------
# find the recipients' addresses per method

# netdata may call us with multiple roles, and roles may have multiple but
# overlapping recipients - so, here we find the unique recipients.
for method_name in ${method_names}; do
	send_var="SEND_${method_name^^}"
	if [ "${!send_var}" = "NO" ]; then
		continue
	fi

	declare -A arr_var=()

	for x in ${roles//,/ }; do
		# the roles 'silent' and 'disabled' mean:
		# don't send a notification for this role
		if [ "${x}" = "silent" ] || [ "${x}" = "disabled" ]; then
			continue
		fi

		role_recipients="role_recipients_${method_name}[$x]"
		default_recipient_var="DEFAULT_RECIPIENT_${method_name^^}"

		a="${!role_recipients}"
		[ -z "${a}" ] && a="${!default_recipient_var}"
		for r in ${a//,/ }; do
			[ "${r}" != "disabled" ] && filter_recipient_by_criticality ${method_name} "${r}" && arr_var[${r/|*/}]="1"
		done
	done

	# build the list of recipients
	to_var="to_${method_name}"
	declare to_${method_name}="${!arr_var[*]}"

	[ -z "${!to_var}" ] && declare ${send_var}="NO"
done

# -----------------------------------------------------------------------------
# handle fixup of the email recipient list.

fix_to_email() {
	to_email=
	while [ -n "${1}" ]; do
		[ -n "${to_email}" ] && to_email="${to_email}, "
		to_email="${to_email}${1}"
		shift 1
	done
}

# ${to_email} without quotes here
fix_to_email ${to_email}

# -----------------------------------------------------------------------------
# handle output if we're running in unit test mode
if [ ${unittest} ]; then
	for method_name in ${method_names}; do
		to_var="to_${method_name}"
		echo "results: ${method_name}: ${!to_var}"
	done
	exit 0
fi

# -----------------------------------------------------------------------------
# check that we have at least a method enabled
proceed=0
for method in "${SEND_EMAIL}" \
	"${SEND_PUSHOVER}" \
	"${SEND_TELEGRAM}" \
	"${SEND_SLACK}" \
	"${SEND_ROCKETCHAT}" \
	"${SEND_ALERTA}" \
	"${SEND_FLOCK}" \
	"${SEND_DISCORD}" \
	"${SEND_TWILIO}" \
	"${SEND_HIPCHAT}" \
	"${SEND_MESSAGEBIRD}" \
	"${SEND_KAVENEGAR}" \
	"${SEND_PUSHBULLET}" \
	"${SEND_KAFKA}" \
	"${SEND_PD}" \
	"${SEND_FLEEP}" \
	"${SEND_PROWL}" \
	"${SEND_CUSTOM}" \
	"${SEND_IRC}" \
	"${SEND_AWSSNS}" \
	"${SEND_SYSLOG}" \
	"${SEND_SMS}" \
	"${SEND_MSTEAM}"; do
	if [ "${method}" == "YES" ]; then
		proceed=1
		break
	fi
done
if [ "$proceed" -eq 0 ]; then
	fatal "All notification methods are disabled. Not sending notification for host '${host}', chart '${chart}' to '${roles}' for '${name}' = '${value}' for status '${status}'."
fi

# -----------------------------------------------------------------------------
# get the date the alarm happened

date=$(date --date=@${when} "${date_format}" 2>/dev/null)
[ -z "${date}" ] && date=$(date "${date_format}" 2>/dev/null)
[ -z "${date}" ] && date=$(date --date=@${when} 2>/dev/null)
[ -z "${date}" ] && date=$(date 2>/dev/null)

# ----------------------------------------------------------------------------
# prepare some extra headers if we've been asked to thread e-mails
if [ "${SEND_EMAIL}" == "YES" ] && [ "${EMAIL_THREADING}" != "NO" ]; then
	email_thread_headers="In-Reply-To: <${chart}-${name}@${host}>\\r\\nReferences: <${chart}-${name}@${host}>"
else
	email_thread_headers=
fi

# -----------------------------------------------------------------------------
# function to URL encode a string

urlencode() {
	local string="${1}" strlen encoded pos c o

	strlen=${#string}
	for ((pos = 0; pos < strlen; pos++)); do
		c=${string:pos:1}
		case "${c}" in
		[-_.~a-zA-Z0-9])
			o="${c}"
			;;

		*)
			printf -v o '%%%02x' "'${c}"
			;;
		esac
		encoded+="${o}"
	done

	REPLY="${encoded}"
	echo "${REPLY}"
}

# -----------------------------------------------------------------------------
# function to convert a duration in seconds, to a human readable duration
# using DAYS, MINUTES, SECONDS

duration4human() {
	local s="${1}" d=0 h=0 m=0 ds="day" hs="hour" ms="minute" ss="second" ret
	d=$((s / 86400))
	s=$((s - (d * 86400)))
	h=$((s / 3600))
	s=$((s - (h * 3600)))
	m=$((s / 60))
	s=$((s - (m * 60)))

	if [ ${d} -gt 0 ]; then
		[ ${m} -ge 30 ] && h=$((h + 1))
		[ ${d} -gt 1 ] && ds="days"
		[ ${h} -gt 1 ] && hs="hours"
		if [ ${h} -gt 0 ]; then
			ret="${d} ${ds} and ${h} ${hs}"
		else
			ret="${d} ${ds}"
		fi
	elif [ ${h} -gt 0 ]; then
		[ ${s} -ge 30 ] && m=$((m + 1))
		[ ${h} -gt 1 ] && hs="hours"
		[ ${m} -gt 1 ] && ms="minutes"
		if [ ${m} -gt 0 ]; then
			ret="${h} ${hs} and ${m} ${ms}"
		else
			ret="${h} ${hs}"
		fi
	elif [ ${m} -gt 0 ]; then
		[ ${m} -gt 1 ] && ms="minutes"
		[ ${s} -gt 1 ] && ss="seconds"
		if [ ${s} -gt 0 ]; then
			ret="${m} ${ms} and ${s} ${ss}"
		else
			ret="${m} ${ms}"
		fi
	else
		[ ${s} -gt 1 ] && ss="seconds"
		ret="${s} ${ss}"
	fi

	REPLY="${ret}"
	echo "${REPLY}"
}

# -----------------------------------------------------------------------------
# email sender

send_email() {
	local ret opts=() sender_email="${EMAIL_SENDER}" sender_name=
	if [ "${SEND_EMAIL}" = "YES" ]; then

		if [ -n "${EMAIL_SENDER}" ]; then
			if [[ ${EMAIL_SENDER} =~ ^\".*\"\ \<.*\>$ ]]; then
				# the name includes double quotes
				sender_email="$(echo "${EMAIL_SENDER}" | cut -d '<' -f 2 | cut -d '>' -f 1)"
				sender_name="$(echo "${EMAIL_SENDER}" | cut -d '"' -f 2)"
			elif [[ ${EMAIL_SENDER} =~ ^\'.*\'\ \<.*\>$ ]]; then
				# the name includes single quotes
				sender_email="$(echo "${EMAIL_SENDER}" | cut -d '<' -f 2 | cut -d '>' -f 1)"
				sender_name="$(echo "${EMAIL_SENDER}" | cut -d "'" -f 2)"
			elif [[ ${EMAIL_SENDER} =~ ^.*\ \<.*\>$ ]]; then
				# the name does not have any quotes
				sender_email="$(echo "${EMAIL_SENDER}" | cut -d '<' -f 2 | cut -d '>' -f 1)"
				sender_name="$(echo "${EMAIL_SENDER}" | cut -d '<' -f 1)"
			fi
		fi

		[ -n "${sender_email}" ] && opts+=(-f "${sender_email}")
		[ -n "${sender_name}" ] && opts+=(-F "${sender_name}")

		if [ "${debug}" = "1" ]; then
			echo >&2 "--- BEGIN sendmail command ---"
			printf >&2 "%q " "${sendmail}" -t "${opts[@]}"
			echo >&2
			echo >&2 "--- END sendmail command ---"
		fi

		"${sendmail}" -t "${opts[@]}"
		ret=$?

		if [ ${ret} -eq 0 ]; then
			info "sent email notification for: ${host} ${chart}.${name} is ${status} to '${to_email}'"
			return 0
		else
			error "failed to send email notification for: ${host} ${chart}.${name} is ${status} to '${to_email}' with error code ${ret}."
			return 1
		fi
	fi

	return 1
}

# -----------------------------------------------------------------------------
# pushover sender

send_pushover() {
	local apptoken="${1}" usertokens="${2}" when="${3}" url="${4}" status="${5}" title="${6}" message="${7}" httpcode sent=0 user priority

	if [ "${SEND_PUSHOVER}" = "YES" ] && [ -n "${apptoken}" ] && [ -n "${usertokens}" ] && [ -n "${title}" ] && [ -n "${message}" ]; then

		# https://pushover.net/api
		priority=-2
		case "${status}" in
		CLEAR) priority=-1 ;; # low priority: no sound or vibration
		WARNING) priority=0 ;; # normal priority: respect quiet hours
		CRITICAL) priority=1 ;; # high priority: bypass quiet hours
		*) priority=-2 ;; # lowest priority: no notification at all
		esac

		for user in ${usertokens}; do
			httpcode=$(docurl \
				--form-string "token=${apptoken}" \
				--form-string "user=${user}" \
				--form-string "html=1" \
				--form-string "title=${title}" \
				--form-string "message=${message}" \
				--form-string "timestamp=${when}" \
				--form-string "url=${url}" \
				--form-string "url_title=Open netdata dashboard to view the alarm" \
				--form-string "priority=${priority}" \
				https://api.pushover.net/1/messages.json)

			if [ "${httpcode}" = "200" ]; then
				info "sent pushover notification for: ${host} ${chart}.${name} is ${status} to '${user}'"
				sent=$((sent + 1))
			else
				error "failed to send pushover notification for: ${host} ${chart}.${name} is ${status} to '${user}' with HTTP error code ${httpcode}."
			fi
		done

		[ ${sent} -gt 0 ] && return 0
	fi

	return 1
}

# -----------------------------------------------------------------------------
# pushbullet sender

send_pushbullet() {
	local userapikey="${1}" source_device="${2}" recipients="${3}" url="${4}" title="${5}" message="${6}" httpcode sent=0 user
	if [ "${SEND_PUSHBULLET}" = "YES" ] && [ -n "${userapikey}" ] && [ -n "${recipients}" ] && [ -n "${message}" ] && [ -n "${title}" ]; then
		#https://docs.pushbullet.com/#create-push
		for user in ${recipients}; do
			httpcode=$(docurl \
				--header 'Access-Token: '${userapikey}'' \
				--header 'Content-Type: application/json' \
				--data-binary @<(
					cat <<EOF
                              {"title": "${title}",
                              "type": "link",
                              "email": "${user}",
                              "body": "$(echo -n ${message})",
                              "url": "${url}",
                              "source_device_iden": "${source_device}"}
EOF
				) "https://api.pushbullet.com/v2/pushes" -X POST)

			if [ "${httpcode}" = "200" ]; then
				info "sent pushbullet notification for: ${host} ${chart}.${name} is ${status} to '${user}'"
				sent=$((sent + 1))
			else
				error "failed to send pushbullet notification for: ${host} ${chart}.${name} is ${status} to '${user}' with HTTP error code ${httpcode}."
			fi
		done

		[ ${sent} -gt 0 ] && return 0
	fi

	return 1
}

# -----------------------------------------------------------------------------
# kafka sender

send_kafka() {
	local httpcode sent=0
	if [ "${SEND_KAFKA}" = "YES" ]; then
		httpcode=$(docurl -X POST \
			--data "{host_ip:\"${KAFKA_SENDER_IP}\",when:${when},name:\"${name}\",chart:\"${chart}\",family:\"${family}\",status:\"${status}\",old_status:\"${old_status}\",value:${value},old_value:${old_value},duration:${duration},non_clear_duration:${non_clear_duration},units:\"${units}\",info:\"${info}\"}" \
			"${KAFKA_URL}")

		if [ "${httpcode}" = "204" ]; then
			info "sent kafka data for: ${host} ${chart}.${name} is ${status} and ip '${KAFKA_SENDER_IP}'"
			sent=$((sent + 1))
		else
			error "failed to send kafka data for: ${host} ${chart}.${name} is ${status} and ip '${KAFKA_SENDER_IP}' with HTTP error code ${httpcode}."
		fi

		[ ${sent} -gt 0 ] && return 0
	fi

	return 1
}

# -----------------------------------------------------------------------------
# pagerduty.com sender

send_pd() {
	local recipients="${1}" sent=0
	unset t
	case ${status} in
	CLEAR) t='resolve' ;;
	WARNING) t='trigger' ;;
	CRITICAL) t='trigger' ;;
	esac

	if [ ${SEND_PD} = "YES" ] && [ -n "${t}" ]; then
		for PD_SERVICE_KEY in ${recipients}; do
			d="${status} ${name} = ${value_string} - ${host}, ${family}"
			payload="$(
				cat <<EOF
            {
              "service_key": "${PD_SERVICE_KEY}",
              "event_type": "${t}",
              "incident_key" : "${alarm_id}",
              "description": "${d}",
              "details": {
                "value_w_units": "${value_string}",
                "when": "${when}",
                "duration" : "${duration}",
                "roles": "${roles}",
                "alarm_id" : "${alarm_id}",
                "name" : "${name}",
                "chart" : "${chart}",
                "family" : "${family}",
                "status" : "${status}",
                "old_status" : "${old_status}",
                "value" : "${value}",
                "old_value" : "${old_value}",
                "src" : "${src}",
                "non_clear_duration" : "${non_clear_duration}",
                "units" : "${units}",
                "info" : "${info}"
              }
            }
EOF
			)"
			httpcode=$(docurl -X POST --data "${payload}" "https://events.pagerduty.com/generic/2010-04-15/create_event.json")
			if [ "${httpcode}" = "200" ]; then
				info "sent pagerduty notification for: ${host} ${chart}.${name} is ${status}'"
				sent=$((sent + 1))
			else
				error "failed to send pagerduty notification for: ${host} ${chart}.${name} is ${status}, with HTTP error code ${httpcode}."
			fi
		done

		[ ${sent} -gt 0 ] && return 0
	fi

	return 1
}

# -----------------------------------------------------------------------------
# twilio sender

send_twilio() {
	local accountsid="${1}" accounttoken="${2}" twilionumber="${3}" recipients="${4}" title="${5}" message="${6}" httpcode sent=0 user
	if [ "${SEND_TWILIO}" = "YES" ] && [ -n "${accountsid}" ] && [ -n "${accounttoken}" ] && [ -n "${twilionumber}" ] && [ -n "${recipients}" ] && [ -n "${message}" ] && [ -n "${title}" ]; then
		#https://www.twilio.com/packages/labs/code/bash/twilio-sms
		for user in ${recipients}; do
			httpcode=$(docurl -X POST \
				--data-urlencode "From=${twilionumber}" \
				--data-urlencode "To=${user}" \
				--data-urlencode "Body=${title} ${message}" \
				-u "${accountsid}:${accounttoken}" \
				"https://api.twilio.com/2010-04-01/Accounts/${accountsid}/Messages.json")

			if [ "${httpcode}" = "201" ]; then
				info "sent Twilio SMS for: ${host} ${chart}.${name} is ${status} to '${user}'"
				sent=$((sent + 1))
			else
				error "failed to send Twilio SMS for: ${host} ${chart}.${name} is ${status} to '${user}' with HTTP error code ${httpcode}."
			fi
		done

		[ ${sent} -gt 0 ] && return 0
	fi

	return 1
}

# -----------------------------------------------------------------------------
# hipchat sender

send_hipchat() {
	local authtoken="${1}" recipients="${2}" message="${3}" httpcode sent=0 room color msg_format notify

	# remove <small></small> from the message
	message="${message//<small>/}"
	message="${message//<\/small>/}"

	if [ "${SEND_HIPCHAT}" = "YES" ] && [ -n "${HIPCHAT_SERVER}" ] && [ -n "${authtoken}" ] && [ -n "${recipients}" ] && [ -n "${message}" ]; then
		# Valid values: html, text.
		# Defaults to 'html'.
		msg_format="html"

		# Background color for message. Valid values: yellow, green, red, purple, gray, random. Defaults to 'yellow'.
		case "${status}" in
		WARNING) color="yellow" ;;
		CRITICAL) color="red" ;;
		CLEAR) color="green" ;;
		*) color="gray" ;;
		esac

		# Whether this message should trigger a user notification (change the tab color, play a sound, notify mobile phones, etc).
		# Each recipient's notification preferences are taken into account.
		# Defaults to false.
		notify="true"

		for room in ${recipients}; do
			httpcode=$(docurl -X POST \
				-H "Content-type: application/json" \
				-H "Authorization: Bearer ${authtoken}" \
				-d "{\"color\": \"${color}\", \"from\": \"${host}\", \"message_format\": \"${msg_format}\", \"message\": \"${message}\", \"notify\": \"${notify}\"}" \
				"https://${HIPCHAT_SERVER}/v2/room/${room}/notification")

			if [ "${httpcode}" = "204" ]; then
				info "sent HipChat notification for: ${host} ${chart}.${name} is ${status} to '${room}'"
				sent=$((sent + 1))
			else
				error "failed to send HipChat notification for: ${host} ${chart}.${name} is ${status} to '${room}' with HTTP error code ${httpcode}."
			fi
		done

		[ ${sent} -gt 0 ] && return 0
	fi

	return 1
}

# -----------------------------------------------------------------------------
# messagebird sender

send_messagebird() {
	local accesskey="${1}" messagebirdnumber="${2}" recipients="${3}" title="${4}" message="${5}" httpcode sent=0 user
	if [ "${SEND_MESSAGEBIRD}" = "YES" ] && [ -n "${accesskey}" ] && [ -n "${messagebirdnumber}" ] && [ -n "${recipients}" ] && [ -n "${message}" ] && [ -n "${title}" ]; then
		#https://developers.messagebird.com/docs/messaging
		for user in ${recipients}; do
			httpcode=$(docurl -X POST \
				--data-urlencode "originator=${messagebirdnumber}" \
				--data-urlencode "recipients=${user}" \
				--data-urlencode "body=${title} ${message}" \
				--data-urlencode "datacoding=auto" \
				-H "Authorization: AccessKey ${accesskey}" \
				"https://rest.messagebird.com/messages")

			if [ "${httpcode}" = "201" ]; then
				info "sent Messagebird SMS for: ${host} ${chart}.${name} is ${status} to '${user}'"
				sent=$((sent + 1))
			else
				error "failed to send Messagebird SMS for: ${host} ${chart}.${name} is ${status} to '${user}' with HTTP error code ${httpcode}."
			fi
		done

		[ ${sent} -gt 0 ] && return 0
	fi

	return 1
}

# -----------------------------------------------------------------------------
# kavenegar sender

send_kavenegar() {
	local API_KEY="${1}" kavenegarsender="${2}" recipients="${3}" title="${4}" message="${5}" httpcode sent=0 user
	if [ "${SEND_KAVENEGAR}" = "YES" ] && [ -n "${API_KEY}" ] && [ -n "${kavenegarsender}" ] && [ -n "${recipients}" ] && [ -n "${message}" ] && [ -n "${title}" ]; then
		# http://api.kavenegar.com/v1/{API-KEY}/sms/send.json
		for user in ${recipients}; do
			httpcode=$(docurl -X POST http://api.kavenegar.com/v1/${API_KEY}/sms/send.json \
				--data-urlencode "sender=${kavenegarsender}" \
				--data-urlencode "receptor=${user}" \
				--data-urlencode "message=${title} ${message}")

			if [ "${httpcode}" = "200" ]; then
				info "sent Kavenegar SMS for: ${host} ${chart}.${name} is ${status} to '${user}'"
				sent=$((sent + 1))
			else
				error "failed to send Kavenegar SMS for: ${host} ${chart}.${name} is ${status} to '${user}' with HTTP error code ${httpcode}."
			fi
		done

		[ ${sent} -gt 0 ] && return 0
	fi

	return 1
}

# -----------------------------------------------------------------------------
# telegram sender

send_telegram() {
	local bottoken="${1}" chatids="${2}" message="${3}" httpcode sent=0 chatid emoji disableNotification=""

	if [ "${status}" = "CLEAR" ]; then disableNotification="--data-urlencode disable_notification=true"; fi

	case "${status}" in
	WARNING) emoji="⚠️" ;;
	CRITICAL) emoji="🔴" ;;
	CLEAR) emoji="✅" ;;
	*) emoji="⚪️" ;;
	esac

	if [ "${SEND_TELEGRAM}" = "YES" ] && [ -n "${bottoken}" ] && [ -n "${chatids}" ] && [ -n "${message}" ]; then
		for chatid in ${chatids}; do
			# https://core.telegram.org/bots/api#sendmessage
			httpcode=$(docurl ${disableNotification} \
				--data-urlencode "parse_mode=HTML" \
				--data-urlencode "disable_web_page_preview=true" \
				--data-urlencode "text=${emoji} ${message}" \
				"https://api.telegram.org/bot${bottoken}/sendMessage?chat_id=${chatid}")

			if [ "${httpcode}" = "200" ]; then
				info "sent telegram notification for: ${host} ${chart}.${name} is ${status} to '${chatid}'"
				sent=$((sent + 1))
			elif [ "${httpcode}" = "401" ]; then
				error "failed to send telegram notification for: ${host} ${chart}.${name} is ${status} to '${chatid}': Wrong bot token."
			else
				error "failed to send telegram notification for: ${host} ${chart}.${name} is ${status} to '${chatid}' with HTTP error code ${httpcode}."
			fi
		done

		[ ${sent} -gt 0 ] && return 0
	fi

	return 1
}

# -----------------------------------------------------------------------------
# Microsoft Team sender

send_msteam() {

	local webhook="${1}" channels="${2}" httpcode sent=0 channel color payload

	[ "${SEND_MSTEAM}" != "YES" ] && return 1

	case "${status}" in
	WARNING) icon="${MSTEAM_ICON_WARNING}" && color="${MSTEAM_COLOR_WARNING}" ;;
	CRITICAL) icon="${MSTEAM_ICON_CRITICAL}" && color="${MSTEAM_COLOR_CRITICAL}" ;;
	CLEAR) icon="${MSTEAM_ICON_CLEAR}" && color="${MSTEAM_COLOR_CLEAR}" ;;
	*) icon="${MSTEAM_ICON_DEFAULT}" && color="${MSTEAM_COLOR_DEFAULT}" ;;
	esac

	for channel in ${channels}; do
		## More details are available here regarding the payload syntax options : https://docs.microsoft.com/en-us/outlook/actionable-messages/message-card-reference
		## Online designer : https://acdesignerbeta.azurewebsites.net/
		payload="$(
			cat <<EOF
        {
            "@context": "http://schema.org/extensions",
            "@type": "MessageCard",
            "themeColor": "${color}",
            "title": "$icon Alert ${status} from netdata for ${host}",
            "text": "${host} ${status_message}, ${chart} (_${family}_), *${alarm}*",
            "potentialAction": [
            {
                "@type": "OpenUri",
                "name": "Netdata",
                "targets": [
                { "os": "default", "uri": "${goto_url}" }
                ]
            }
            ]
        }
EOF
		)"

		# Replacing in the webhook CHANNEL string by the MS Teams channel name from conf file.
		webhook="${webhook//CHANNEL/${channel}}"

		httpcode=$(docurl -H "Content-Type: application/json" -d "${payload}" "${webhook}")

		if [ "${httpcode}" = "200" ]; then
			info "sent Microsoft team notification for: ${host} ${chart}.${name} is ${status} to '${webhook}'"
			sent=$((sent + 1))
		else
			error "failed to send Microsoft team notification for: ${host} ${chart}.${name} is ${status} to '${webhook}', with HTTP error code ${httpcode}."
		fi
	done

	[ ${sent} -gt 0 ] && return 0

	return 1
}

# slack sender

send_slack() {
	local webhook="${1}" channels="${2}" httpcode sent=0 channel color payload

	[ "${SEND_SLACK}" != "YES" ] && return 1

	case "${status}" in
	WARNING) color="warning" ;;
	CRITICAL) color="danger" ;;
	CLEAR) color="good" ;;
	*) color="#777777" ;;
	esac

	for channel in ${channels}; do
		# Default entry in the recipient is without a hash in front (backwards-compatible). Accept specification of channel or user.
		if [ "${channel::1}" != "#" ] && [ "${channel::1}" != "@" ]; then channel="#$channel"; fi

		# If channel is equal to "#" then do not send the channel attribute at all. Slack also defines channels and users in webhooks.
		if [ "${channel}" = "#" ]; then
			ch=""
			chstr="without specifying a channel"
		else
			ch="\"channel\": \"${channel}\","
			chstr="to '${channel}'"
		fi

		payload="$(
			cat <<EOF
        {
            $ch
            "username": "netdata on ${host}",
            "icon_url": "${images_base_url}/images/banner-icon-144x144.png",
            "text": "${host} ${status_message}, \`${chart}\` (_${family}_), *${alarm}*",
            "attachments": [
                {
                    "fallback": "${alarm} - ${chart} (${family}) - ${info}",
                    "color": "${color}",
                    "title": "${alarm}",
                    "title_link": "${goto_url}",
                    "text": "${info}",
                    "fields": [
                        {
                            "title": "${chart}",
                            "short": true
                        },
                        {
                            "title": "${family}",
                            "short": true
                        }
                    ],
                    "thumb_url": "${image}",
                    "footer": "by ${host}",
                    "ts": ${when}
                }
            ]
        }
EOF
		)"

		httpcode=$(docurl -X POST --data-urlencode "payload=${payload}" "${webhook}")
		if [ "${httpcode}" = "200" ]; then
			info "sent slack notification for: ${host} ${chart}.${name} is ${status} ${chstr}"
			sent=$((sent + 1))
		else
			error "failed to send slack notification for: ${host} ${chart}.${name} is ${status} ${chstr}, with HTTP error code ${httpcode}."
		fi
	done

	[ ${sent} -gt 0 ] && return 0

	return 1
}

# -----------------------------------------------------------------------------
# rocketchat sender

send_rocketchat() {
	local webhook="${1}" channels="${2}" httpcode sent=0 channel color payload

	[ "${SEND_ROCKETCHAT}" != "YES" ] && return 1

	case "${status}" in
	WARNING) color="warning" ;;
	CRITICAL) color="danger" ;;
	CLEAR) color="good" ;;
	*) color="#777777" ;;
	esac

	for channel in ${channels}; do
		payload="$(
			cat <<EOF
        {
            "channel": "#${channel}",
            "alias": "netdata on ${host}",
            "avatar": "${images_base_url}/images/banner-icon-144x144.png",
            "text": "${host} ${status_message}, \`${chart}\` (_${family}_), *${alarm}*",
            "attachments": [
                {
                    "color": "${color}",
                    "title": "${alarm}",
                    "title_link": "${goto_url}",
                    "text": "${info}",
                    "fields": [
                        {
                            "title": "${chart}",
                            "short": true,
                            "value": "chart"
                        },
                        {
                            "title": "${family}",
                            "short": true,
                            "value": "family"
                        }
                    ],
                    "thumb_url": "${image}",
                    "ts": "${when}"
                }
            ]
        }
EOF
		)"

		httpcode=$(docurl -X POST --data-urlencode "payload=${payload}" "${webhook}")
		if [ "${httpcode}" = "200" ]; then
			info "sent rocketchat notification for: ${host} ${chart}.${name} is ${status} to '${channel}'"
			sent=$((sent + 1))
		else
			error "failed to send rocketchat notification for: ${host} ${chart}.${name} is ${status} to '${channel}', with HTTP error code ${httpcode}."
		fi
	done

	[ ${sent} -gt 0 ] && return 0

	return 1
}

# -----------------------------------------------------------------------------
# alerta sender

send_alerta() {
	local webhook="${1}" channels="${2}" httpcode sent=0 channel severity resource event payload auth

	[ "${SEND_ALERTA}" != "YES" ] && return 1

	case "${status}" in
	CRITICAL) severity="critical" ;;
	WARNING) severity="warning" ;;
	CLEAR) severity="cleared" ;;
	*) severity="indeterminate" ;;
	esac

	if [[ ${chart} == httpcheck* ]]; then
		resource=$chart
		event=$name
	else
		resource="${host}:${family}"
		event="${chart}.${name}"
	fi

	for channel in ${channels}; do
		payload="$(
			cat <<EOF
        {
            "resource": "${resource}",
            "event": "${event}",
            "environment": "${channel}",
            "severity": "${severity}",
            "service": ["Netdata"],
            "group": "Performance",
            "value": "${value_string}",
            "text": "${info}",
            "tags": ["alarm_id:${alarm_id}"],
            "attributes": {
                "roles": "${roles}",
                "name": "${name}",
                "chart": "${chart}",
                "family": "${family}",
                "source": "${src}",
                "moreInfo": "<a href=\"${goto_url}\">View Netdata</a>"
            },
            "origin": "netdata/${host}",
            "type": "netdataAlarm",
            "rawData": "${BASH_ARGV[@]}"
        }
EOF
		)"

		if [ -n "${ALERTA_API_KEY}" ]; then
			auth="Key ${ALERTA_API_KEY}"
		fi

		httpcode=$(docurl -X POST "${webhook}/alert" -H "Content-Type: application/json" -H "Authorization: $auth" --data "${payload}")

		if [ "${httpcode}" = "200" ] || [ "${httpcode}" = "201" ]; then
			info "sent alerta notification for: ${host} ${chart}.${name} is ${status} to '${channel}'"
			sent=$((sent + 1))
		elif [ "${httpcode}" = "202" ]; then
			info "suppressed alerta notification for: ${host} ${chart}.${name} is ${status} to '${channel}'"
		else
			error "failed to send alerta notification for: ${host} ${chart}.${name} is ${status} to '${channel}', with HTTP error code ${httpcode}."
		fi
	done

	[ ${sent} -gt 0 ] && return 0

	return 1
}

# -----------------------------------------------------------------------------
# flock sender

send_flock() {
	local webhook="${1}" channels="${2}" httpcode sent=0 channel color payload

	[ "${SEND_FLOCK}" != "YES" ] && return 1

	case "${status}" in
	WARNING) color="warning" ;;
	CRITICAL) color="danger" ;;
	CLEAR) color="good" ;;
	*) color="#777777" ;;
	esac

	for channel in ${channels}; do
		httpcode=$(docurl -X POST "${webhook}" -H "Content-Type: application/json" -d "{
            \"sendAs\": {
                \"name\" : \"netdata on ${host}\",
                \"profileImage\" : \"${images_base_url}/images/banner-icon-144x144.png\"
            },
            \"text\": \"${host} *${status_message}*\",
            \"timestamp\": \"${when}\",
            \"attachments\": [
                {
                    \"description\": \"${chart} (${family}) - ${info}\",
                    \"color\": \"${color}\",
                    \"title\": \"${alarm}\",
                    \"url\": \"${goto_url}\",
                    \"text\": \"${info}\",
                    \"views\": {
                        \"image\": {
                            \"original\": { \"src\": \"${image}\", \"width\": 400, \"height\": 400 },
                            \"thumbnail\": { \"src\": \"${image}\", \"width\": 50, \"height\": 50 },
                            \"filename\": \"${image}\"
                            }
                    }
                }
            ]
        }")
		if [ "${httpcode}" = "200" ]; then
			info "sent flock notification for: ${host} ${chart}.${name} is ${status} to '${channel}'"
			sent=$((sent + 1))
		else
			error "failed to send flock notification for: ${host} ${chart}.${name} is ${status} to '${channel}', with HTTP error code ${httpcode}."
		fi
	done

	[ ${sent} -gt 0 ] && return 0

	return 1
}

# -----------------------------------------------------------------------------
# discord sender

send_discord() {
	local webhook="${1}/slack" channels="${2}" httpcode sent=0 channel color payload username

	[ "${SEND_DISCORD}" != "YES" ] && return 1

	case "${status}" in
	WARNING) color="warning" ;;
	CRITICAL) color="danger" ;;
	CLEAR) color="good" ;;
	*) color="#777777" ;;
	esac

	for channel in ${channels}; do
		username="netdata on ${host}"
		[ ${#username} -gt 32 ] && username="${username:0:29}..."

		payload="$(
			cat <<EOF
        {
            "channel": "#${channel}",
            "username": "${username}",
            "text": "${host} ${status_message}, \`${chart}\` (_${family}_), *${alarm}*",
            "icon_url": "${images_base_url}/images/banner-icon-144x144.png",
            "attachments": [
                {
                    "color": "${color}",
                    "title": "${alarm}",
                    "title_link": "${goto_url}",
                    "text": "${info}",
                    "fields": [
                        {
                            "title": "${chart}",
                            "value": "${family}"
                        }
                    ],
                    "thumb_url": "${image}",
                    "footer_icon": "${images_base_url}/images/banner-icon-144x144.png",
                    "footer": "${host}",
                    "ts": ${when}
                }
            ]
        }
EOF
		)"

		httpcode=$(docurl -X POST --data-urlencode "payload=${payload}" "${webhook}")
		if [ "${httpcode}" = "200" ]; then
			info "sent discord notification for: ${host} ${chart}.${name} is ${status} to '${channel}'"
			sent=$((sent + 1))
		else
			error "failed to send discord notification for: ${host} ${chart}.${name} is ${status} to '${channel}', with HTTP error code ${httpcode}."
		fi
	done

	[ ${sent} -gt 0 ] && return 0

	return 1
}

# -----------------------------------------------------------------------------
# fleep sender

send_fleep() {
	local httpcode sent=0 webhooks="${1}" data message
	if [ "${SEND_FLEEP}" = "YES" ]; then
		message="${host} ${status_message}, \`${chart}\` (${family}), *${alarm}*\\n${info}"

		for hook in ${webhooks}; do
			data="{ "
			data="${data} 'message': '${message}', "
			data="${data} 'user': '${FLEEP_SENDER}' "
			data="${data} }"

			httpcode=$(docurl -X POST --data "${data}" "https://fleep.io/hook/${hook}")

			if [ "${httpcode}" = "200" ]; then
				info "sent fleep data for: ${host} ${chart}.${name} is ${status} and user '${FLEEP_SENDER}'"
				sent=$((sent + 1))
			else
				error "failed to send fleep data for: ${host} ${chart}.${name} is ${status} and user '${FLEEP_SENDER}' with HTTP error code ${httpcode}."
			fi
		done

		[ ${sent} -gt 0 ] && return 0
	fi

	return 1
}

# -----------------------------------------------------------------------------
# Prowl sender

send_prowl() {
	local httpcode sent=0 data message keys prio=0 alarm_url event
	if [ "${SEND_PROWL}" = "YES" ]; then
		message="$(urlencode "${host} ${status_message}, \`${chart}\` (${family}), *${alarm}*\\n${info}")"
		message="description=${message}"
		keys="$(urlencode "$(echo "${1}" | tr ' ' ,)")"
		keys="apikey=${keys}"
		app="application=Netdata"

		case "${status}" in
		CRITICAL)
			prio=2
			;;
		WARNING)
			prio=1
			;;
		esac
		prio="priority=${prio}"

		alarm_url="$(urlencode ${goto_url})"
		alarm_url="url=${alarm_url}"
		event="$(urlencode "${host} ${status_message}")"
		event="event=${event}"

		data="${keys}&${prio}&${alarm_url}&${app}&${event}&${message}"

		httpcode=$(docurl -X POST --data "${data}" "https://api.prowlapp.com/publicapi/add")

		if [ "${httpcode}" = "200" ]; then
			info "sent prowl data for: ${host} ${chart}.${name} is ${status}"
			sent=1
		else
			error "failed to send prowl data for: ${host} ${chart}.${name} is ${status} with with error code ${httpcode}."
		fi

		[ ${sent} -gt 0 ] && return 0
	fi

	return 1
}

# -----------------------------------------------------------------------------
# irc sender

send_irc() {
	local NICKNAME="${1}" REALNAME="${2}" CHANNELS="${3}" NETWORK="${4}" SERVERNAME="${5}" MESSAGE="${6}" sent=0 channel color send_alarm reply_codes error

	if [ "${SEND_IRC}" = "YES" ] && [ -n "${NICKNAME}" ] && [ -n "${REALNAME}" ] && [ -n "${CHANNELS}" ] && [ -n "${NETWORK}" ] && [ -n "${SERVERNAME}" ]; then
		case "${status}" in
		WARNING) color="warning" ;;
		CRITICAL) color="danger" ;;
		CLEAR) color="good" ;;
		*) color="#777777" ;;
		esac

		for CHANNEL in ${CHANNELS}; do
			error=0
			send_alarm=$(echo -e "USER ${NICKNAME} guest ${REALNAME} ${SERVERNAME}\\nNICK ${NICKNAME}\\nJOIN ${CHANNEL}\\nPRIVMSG ${CHANNEL} :${MESSAGE}\\nQUIT\\n" \  | nc "${NETWORK}" 6667)
			reply_codes=$(echo "${send_alarm}" | cut -d ' ' -f 2 | grep -o '[0-9]*')
			for code in ${reply_codes}; do
				if [ "${code}" -ge 400 ] && [ "${code}" -le 599 ]; then
					error=1
					break
				fi
			done

			if [ "${error}" -eq 0 ]; then
				info "sent irc notification for: ${host} ${chart}.${name} is ${status} to '${CHANNEL}'"
				sent=$((sent + 1))
			else
				error "failed to send irc notification for: ${host} ${chart}.${name} is ${status} to '${CHANNEL}', with error code ${code}."
			fi
		done
	fi

	[ ${sent} -gt 0 ] && return 0

	return 1
}

# -----------------------------------------------------------------------------
# Amazon SNS sender

send_awssns() {
	local targets="${1}" message='' sent=0 region=''
	local default_format="${status} on ${host} at ${date}: ${chart} ${value_string}"

	[ "${SEND_AWSSNS}" = "YES" ] || return 1

	message=${AWSSNS_MESSAGE_FORMAT:-${default_format}}

	for target in ${targets}; do
		# Extract the region from the target ARN.  We need to explicitly specify the region so that it matches up correctly.
		region="$(echo ${target} | cut -f 4 -d ':')"
		if ${aws} sns publish --region "${region}" --subject "${host} ${status_message} - ${name//_/ } - ${chart}" --message "${message}" --target-arn ${target} &>/dev/null; then
			info "sent Amazon SNS notification for: ${host} ${chart}.${name} is ${status} to '${target}'"
			sent=$((sent + 1))
		else
			error "failed to send Amazon SNS notification for: ${host} ${chart}.${name} is ${status} to '${target}'"
		fi
	done

	[ ${sent} -gt 0 ] && return 0

	return 1
}

# -----------------------------------------------------------------------------
# syslog sender

send_syslog() {
	local facility=${SYSLOG_FACILITY:-"local6"} level='info' targets="${1}"
	local priority='' message='' host='' port='' prefix=''
	local temp1='' temp2=''

	[ "${SEND_SYSLOG}" = "YES" ] || return 1

	if [ "${status}" = "CRITICAL" ]; then
		level='crit'
	elif [ "${status}" = "WARNING" ]; then
		level='warning'
	fi

	for target in ${targets}; do
		priority="${facility}.${level}"
		message=''
		host=''
		port=''
		prefix=''
		temp1=''
		temp2=''

		prefix=$(echo ${target} | cut -d '/' -f 2)
		temp1=$(echo ${target} | cut -d '/' -f 1)

		if [ ${prefix} != ${temp1} ]; then
			if (echo ${temp1} | grep -q '@'); then
				temp2=$(echo ${temp1} | cut -d '@' -f 1)
				host=$(echo ${temp1} | cut -d '@' -f 2)

				if [ ${temp2} != ${host} ]; then
					priority=${temp2}
				fi

				port=$(echo ${host} | rev | cut -d ':' -f 1 | rev)

				if (echo ${host} | grep -E -q '\[.*\]'); then
					if (echo ${port} | grep -q ']'); then
						port=''
					else
						host=$(echo ${host} | rev | cut -d ':' -f 2- | rev)
					fi
				else
					if [ ${port} = ${host} ]; then
						port=''
					else
						host=$(echo ${host} | cut -d ':' -f 1)
					fi
				fi
			else
				priority=${temp1}
			fi
		fi

		message="${prefix} ${status} on ${host} at ${date}: ${chart} ${value_string}"

		if [ ${host} ]; then
			logger_options="${logger_options} -n ${host}"
			if [ ${port} ]; then
				logger_options="${logger_options} -P ${port}"
			fi
		fi

		${logger} -p ${priority} ${logger_options} "${message}"
	done

	return $?
}

# -----------------------------------------------------------------------------
# SMS sender

send_sms() {
	local recipients="${1}" errcode errmessage sent=0

    # Human readable SMS
    local msg="${host} ${status_message}: ${chart} (${family}), ${alarm}"

    # limit it to 160 characters
    msg="${msg:0:160}"

	if [ "${SEND_SMS}" = "YES" ] && [ -n "${sendsms}" ] && [ -n "${recipients}" ] && [ -n "${msg}" ]; then
		# http://api.kavenegar.com/v1/{API-KEY}/sms/send.json
		for phone in ${recipients}; do
			errmessage=$($sendsms $phone "$msg" 2>&1)
			errcode=$?
			if [ ${errcode} -eq 0 ]; then
				info "sent smstools3 SMS for: ${host} ${chart}.${name} is ${status} to '${user}'"
				sent=$((sent + 1))
			else
				error "failed to send smstools3 SMS for: ${host} ${chart}.${name} is ${status} to '${user}' with error code ${errcode}: ${errmessage}."
			fi
		done

		[ ${sent} -gt 0 ] && return 0
	fi

	return 1
}

# -----------------------------------------------------------------------------
# prepare the content of the notification

# the url to send the user on click
urlencode "${args_host}" >/dev/null
url_host="${REPLY}"
urlencode "${chart}" >/dev/null
url_chart="${REPLY}"
urlencode "${family}" >/dev/null
url_family="${REPLY}"
urlencode "${name}" >/dev/null
url_name="${REPLY}"

redirect_params="host=${url_host}&chart=${url_chart}&family=${url_family}&alarm=${url_name}&alarm_unique_id=${unique_id}&alarm_id=${alarm_id}&alarm_event_id=${event_id}"
GOTOCLOUD=0

if [ "${NETDATA_REGISTRY_URL}" == "https://registry.my-netdata.io" ]; then
	if [ -z "${NETDATA_REGISTRY_UNIQUE_ID}" ]; then
		if [ -f "/var/lib/netdata/registry/netdata.public.unique.id" ]; then
			NETDATA_REGISTRY_UNIQUE_ID="$(cat "/var/lib/netdata/registry/netdata.public.unique.id")"
		fi
	fi
	if [ -n "${NETDATA_REGISTRY_UNIQUE_ID}" ]; then
		GOTOCLOUD=1
	fi
fi

if [ ${GOTOCLOUD} -eq 0 ]; then
	goto_url="${NETDATA_REGISTRY_URL}/goto-host-from-alarm.html?${redirect_params}"
else
	goto_url="${NETDATA_REGISTRY_CLOUD_BASE_URL}/alarms/redirect?agentID=${NETDATA_REGISTRY_UNIQUE_ID}&${redirect_params}"
fi

# the severity of the alarm
severity="${status}"

# the time the alarm was raised
duration4human ${duration} >/dev/null
duration_txt="${REPLY}"
duration4human ${non_clear_duration} >/dev/null
non_clear_duration_txt="${REPLY}"
raised_for="(was ${old_status,,} for ${duration_txt})"

# the key status message
status_message="status unknown"

# the color of the alarm
color="grey"

# the alarm value
alarm="${name//_/ } = ${value_string}"

# the image of the alarm
image="${images_base_url}/images/banner-icon-144x144.png"

# prepare the title based on status
case "${status}" in
CRITICAL)
	image="${images_base_url}/images/alert-128-red.png"
	status_message="is critical"
	color="#ca414b"
	;;

WARNING)
	image="${images_base_url}/images/alert-128-orange.png"
	status_message="needs attention"
	color="#ffc107"
	;;

CLEAR)
	image="${images_base_url}/images/check-mark-2-128-green.png"
	status_message="recovered"
	color="#77ca6d"
	;;
esac

if [ "${status}" = "CLEAR" ]; then
	severity="Recovered from ${old_status}"
	if [ ${non_clear_duration} -gt ${duration} ]; then
		raised_for="(alarm was raised for ${non_clear_duration_txt})"
	fi

	# don't show the value when the status is CLEAR
	# for certain alarms, this value might not have any meaning
	alarm="${name//_/ } ${raised_for}"

elif { [ "${old_status}" = "WARNING" ] && [ "${status}" = "CRITICAL" ]; }; then
	severity="Escalated to ${status}"
	if [ ${non_clear_duration} -gt ${duration} ]; then
		raised_for="(alarm is raised for ${non_clear_duration_txt})"
	fi

elif { [ "${old_status}" = "CRITICAL" ] && [ "${status}" = "WARNING" ]; }; then
	severity="Demoted to ${status}"
	if [ ${non_clear_duration} -gt ${duration} ]; then
		raised_for="(alarm is raised for ${non_clear_duration_txt})"
	fi

else
	raised_for=
fi

# prepare HTML versions of elements
info_html=
[ -n "${info}" ] && info_html=" <small><br/>${info}</small>"

raised_for_html=
[ -n "${raised_for}" ] && raised_for_html="<br/><small>${raised_for}</small>"

# -----------------------------------------------------------------------------
# send the slack notification

# slack aggregates posts from the same username
# so we use "${host} ${status}" as the bot username, to make them diff

send_slack "${SLACK_WEBHOOK_URL}" "${to_slack}"
SENT_SLACK=$?

# -----------------------------------------------------------------------------
# send the Microsoft notification

# Microsoft team aggregates posts from the same username
# so we use "${host} ${status}" as the bot username, to make them diff

send_msteam "${MSTEAM_WEBHOOK_URL}" "${to_msteam}"
SENT_MSTEAM=$?

# -----------------------------------------------------------------------------
# send the rocketchat notification

# rocketchat aggregates posts from the same username
# so we use "${host} ${status}" as the bot username, to make them diff

send_rocketchat "${ROCKETCHAT_WEBHOOK_URL}" "${to_rocketchat}"
SENT_ROCKETCHAT=$?

# -----------------------------------------------------------------------------
# send the alerta notification

# alerta aggregates posts from the same username
# so we use "${host} ${status}" as the bot username, to make them diff

send_alerta "${ALERTA_WEBHOOK_URL}" "${to_alerta}"
SENT_ALERTA=$?

# -----------------------------------------------------------------------------
# send the flock notification

# flock aggregates posts from the same username
# so we use "${host} ${status}" as the bot username, to make them diff

send_flock "${FLOCK_WEBHOOK_URL}" "${to_flock}"
SENT_FLOCK=$?

# -----------------------------------------------------------------------------
# send the discord notification

# discord aggregates posts from the same username
# so we use "${host} ${status}" as the bot username, to make them diff

send_discord "${DISCORD_WEBHOOK_URL}" "${to_discord}"
SENT_DISCORD=$?

# -----------------------------------------------------------------------------
# send the pushover notification

send_pushover "${PUSHOVER_APP_TOKEN}" "${to_pushover}" "${when}" "${goto_url}" "${status}" "${host} ${status_message} - ${name//_/ } - ${chart}" "
<font color=\"${color}\"><b>${alarm}</b></font>${info_html}<br/>&nbsp;
<small><b>${chart}</b><br/>Chart<br/>&nbsp;</small>
<small><b>${family}</b><br/>Family<br/>&nbsp;</small>
<small><b>${severity}</b><br/>Severity<br/>&nbsp;</small>
<small><b>${date}${raised_for_html}</b><br/>Time<br/>&nbsp;</small>
<a href=\"${goto_url}\">View Netdata</a><br/>&nbsp;
<small><small>The source of this alarm is line ${src}</small></small>
"

SENT_PUSHOVER=$?

# -----------------------------------------------------------------------------
# send the pushbullet notification

send_pushbullet "${PUSHBULLET_ACCESS_TOKEN}" "${PUSHBULLET_SOURCE_DEVICE}" "${to_pushbullet}" "${goto_url}" "${host} ${status_message} - ${name//_/ } - ${chart}" "${alarm}\\n
Severity: ${severity}\\n
Chart: ${chart}\\n
Family: ${family}\\n
${date}\\n
The source of this alarm is line ${src}"

SENT_PUSHBULLET=$?

# -----------------------------------------------------------------------------
# send the twilio SMS

send_twilio "${TWILIO_ACCOUNT_SID}" "${TWILIO_ACCOUNT_TOKEN}" "${TWILIO_NUMBER}" "${to_twilio}" "${host} ${status_message} - ${name//_/ } - ${chart}" "${alarm}
Severity: ${severity}
Chart: ${chart}
Family: ${family}
${info}"

SENT_TWILIO=$?

# -----------------------------------------------------------------------------
# send the messagebird SMS

send_messagebird "${MESSAGEBIRD_ACCESS_KEY}" "${MESSAGEBIRD_NUMBER}" "${to_messagebird}" "${host} ${status_message} - ${name//_/ } - ${chart}" "${alarm}
Severity: ${severity}
Chart: ${chart}
Family: ${family}
${info}"

SENT_MESSAGEBIRD=$?

# -----------------------------------------------------------------------------
# send the kavenegar SMS

send_kavenegar "${KAVENEGAR_API_KEY}" "${KAVENEGAR_SENDER}" "${to_kavenegar}" "${host} ${status_message} - ${name//_/ } - ${chart}" "${alarm}
Severity: ${severity}
Chart: ${chart}
Family: ${family}
${info}"

SENT_KAVENEGAR=$?

# -----------------------------------------------------------------------------
# send the telegram.org message

# https://core.telegram.org/bots/api#formatting-options
send_telegram "${TELEGRAM_BOT_TOKEN}" "${to_telegram}" "${host} ${status_message} - <b>${name//_/ }</b>
${chart} (${family})
<a href=\"${goto_url}\">${alarm}</a>
<i>${info}</i>"

SENT_TELEGRAM=$?

# -----------------------------------------------------------------------------
# send the kafka message

send_kafka
SENT_KAFKA=$?

# -----------------------------------------------------------------------------
# send the pagerduty.com message

send_pd "${to_pd}"
SENT_PD=$?

# -----------------------------------------------------------------------------
# send the fleep message

send_fleep "${to_fleep}"
SENT_FLEEP=$?

# -----------------------------------------------------------------------------
# send the Prowl message

send_prowl "${to_prowl}"
SENT_PROWL=$?

# -----------------------------------------------------------------------------
# send the irc message

send_irc "${IRC_NICKNAME}" "${IRC_REALNAME}" "${to_irc}" "${IRC_NETWORK}" "${host}" "${host} ${status_message} - ${name//_/ } - ${chart} ----- ${alarm}
Severity: ${severity}
Chart: ${chart}
Family: ${family}
${info}"

SENT_IRC=$?

# -----------------------------------------------------------------------------
# send the SMS message with smstools3

send_sms "${to_sms}"

SENT_SMS=$?

# -----------------------------------------------------------------------------
# send the custom message

send_custom() {
	# is it enabled?
	[ "${SEND_CUSTOM}" != "YES" ] && return 1

	# do we have any sender?
	[ -z "${1}" ] && return 1

	# call the custom_sender function
	custom_sender "${@}"
}

send_custom "${to_custom}"
SENT_CUSTOM=$?

# -----------------------------------------------------------------------------
# send hipchat message

send_hipchat "${HIPCHAT_AUTH_TOKEN}" "${to_hipchat}" " \
${host} ${status_message}<br/> \
<b>${alarm}</b> ${info_html}<br/> \
<b>${chart}</b> (family <b>${family}</b>)<br/> \
<b>${date}${raised_for_html}</b><br/> \
<a href=\\\"${goto_url}\\\">View netdata dashboard</a> \
(source of alarm ${src}) \
"

SENT_HIPCHAT=$?

# -----------------------------------------------------------------------------
# send the Amazon SNS message

send_awssns "${to_awssns}"

SENT_AWSSNS=$?

# -----------------------------------------------------------------------------
# send the syslog message

send_syslog "${to_syslog}"

SENT_SYSLOG=$?

# -----------------------------------------------------------------------------
# send the email

IFS='' read -r -d '' email_plaintext_part <<EOF
Content-Type: text/plain; encoding=${EMAIL_CHARSET}
Content-Disposition: inline
Content-Transfer-Encoding: 8bit

${host} ${status_message}

${alarm} ${info}
${raised_for}

Chart   : ${chart}
Family  : ${family}
Severity: ${severity}
URL     : ${goto_url}
Source  : ${src}
Date    : ${date}
Notification generated on ${host}

Evaluated Expression :  ${calc_expression}
Expression Variables :  ${calc_param_values}

The host has ${total_warnings} WARNING and ${total_critical} CRITICAL alarm(s) raised.
EOF

if [[ "${EMAIL_PLAINTEXT_ONLY}" == "YES" ]]; then

send_email <<EOF
To: ${to_email}
Subject: ${host} ${status_message} - ${name//_/ } - ${chart}
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="multipart-boundary"
${email_thread_headers}

This is a MIME-encoded multipart message

--multipart-boundary
${email_plaintext_part}
--multipart-boundary--
EOF

else

IFS='' read -r -d '' email_html_part <<EOF
Content-Type: text/html; encoding=${EMAIL_CHARSET}
Content-Disposition: inline
Content-Transfer-Encoding: 8bit

<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; box-sizing: border-box; font-size: 14px; margin: 0; padding: 0;">
<body style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 14px; width: 100% !important; min-height: 100%; line-height: 1.6; background: #f6f6f6; margin:0; padding: 0;">
<table>
    <tbody>
    <tr>
        <td style="vertical-align: top;" valign="top"></td>
        <td width="700" style="vertical-align: top; display: block !important; max-width: 700px !important; clear: both !important; margin: 0 auto; padding: 0;" valign="top">
            <div style="max-width: 700px; display: block; margin: 0 auto; padding: 20px;">
                <table width="100%" cellpadding="0" cellspacing="0" style="background: #fff; border: 1px solid #e9e9e9;">
                    <tbody>
                    <tr>
                        <td bgcolor="#eee" style="padding: 5px 20px 5px 20px; background-color: #eee;">
                            <div style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 20px; color: #777; font-weight: bold;">netdata notification</div>
                        </td>
                    </tr>
                    <tr>
                        <td bgcolor="${color}" style="font-size: 16px; vertical-align: top; font-weight: 400; text-align: center; margin: 0; padding: 10px; color: #ffffff; background: ${color} !important; border: 1px solid ${color}; border-top-color: ${color};" align="center" valign="top">
                            <h1 style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-weight: 400; margin: 0;">${host} ${status_message}</h1>
                        </td>
                    </tr>
                    <tr>
                        <td style="vertical-align: top;" valign="top">
                            <div style="margin: 0; padding: 20px; max-width: 700px;">
                                <table width="100%" cellpadding="0" cellspacing="0" style="max-width:700px">
                                    <tbody>
                                    <tr>
                                        <td style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 18px; vertical-align: top; margin: 0; padding:0 0 20px;" align="left" valign="top">
                                            <span>${chart}</span>
                                            <span style="display: block; color: #666666; font-size: 12px; font-weight: 300; line-height: 1; text-transform: uppercase;">Chart</span>
                                        </td>
                                    </tr>
                                    <tr style="margin: 0; padding: 0;">
                                        <td style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 18px; vertical-align: top; margin: 0; padding: 0 0 20px;" align="left" valign="top">
                                            <span><b>${alarm}</b>${info_html}</span>
                                            <span style="display: block; color: #666666; font-size: 12px; font-weight: 300; line-height: 1; text-transform: uppercase;">Alarm</span>
                                        </td>
                                    </tr>
                                    <tr>
                                        <td style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 18px; vertical-align: top; margin: 0; padding: 0 0 20px;" align="left" valign="top">
                                            <span>${family}</span>
                                            <span style="display: block; color: #666666; font-size: 12px; font-weight: 300; line-height: 1; text-transform: uppercase;">Family</span>
                                        </td>
                                    </tr>
                                    <tr style="margin: 0; padding: 0;">
                                        <td style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 18px; vertical-align: top; margin: 0; padding: 0 0 20px;" align="left" valign="top">
                                            <span>${severity}</span>
                                            <span style="display: block; color: #666666; font-size: 12px; font-weight: 300; line-height: 1; text-transform: uppercase;">Severity</span>
                                        </td>
                                    </tr>
                                    <tr style="margin: 0; padding: 0;">
                                        <td style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 18px; vertical-align: top; margin: 0; padding: 0 0 20px;" align="left" valign="top"><span>${date}</span>
                                            <span>${raised_for_html}</span> <span style="display: block; color: #666666; font-size: 12px; font-weight: 300; line-height: 1; text-transform: uppercase;">Time</span>
                                        </td>
                                    </tr>
                                    <tr style="margin: 0; padding: 0;">
                                        <td style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 18px; vertical-align: top; margin: 0; padding: 0 0 20px;" align="left" valign="top">
                                            <span>${calc_expression}</span>
                                            <span style="display: block; color: #666666; font-size: 12px; font-weight: 300; line-height: 1; text-transform: uppercase;">Evaluated Expression</span>
                                        </td>
                                    </tr>
                                     <tr style="margin: 0; padding: 0;">
                                        <td style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 18px; vertical-align: top; margin: 0; padding: 0 0 20px;" align="left" valign="top">
                                            <span>${calc_param_values}</span>
                                            <span style="display: block; color: #666666; font-size: 12px; font-weight: 300; line-height: 1; text-transform: uppercase;">Expression Variables</span>
                                        </td>
                                    </tr>
                                     <tr style="margin: 0; padding: 0;">
                                        <td style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 18px; vertical-align: top; margin: 0; padding: 0 0 20px;" align="left" valign="top">
                                            The host has ${total_warnings} WARNING and ${total_critical} CRITICAL alarm(s) raised.
                                         </td>
                                    </tr>

                                    <tr style="margin: 0; padding: 0;">
                                        <td style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 18px; vertical-align: top; margin: 0; padding: 0 0 20px;">
                                            <a href="${goto_url}" style="font-size: 14px; color: #ffffff; text-decoration: none; line-height: 1.5; font-weight: bold; text-align: center; display: inline-block; text-transform: capitalize; background: #35568d; border-width: 1px; border-style: solid; border-color: #2b4c86; margin: 0; padding: 10px 15px;" target="_blank">View Netdata</a>
                                        </td>
                                    </tr>
                                    <tr style="text-align: center; margin: 0; padding: 0;">
                                        <td style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 11px; vertical-align: top; margin: 0; padding: 10px 0 0 0; color: #666666;" align="center" valign="bottom">The source of this alarm is line <code>${src}</code><br/>(alarms are configurable, edit this file to adapt the alarm to your needs)
                                        </td>
                                    </tr>
                                    <tr style="text-align: center; margin: 0; padding: 0;">
                                        <td style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 12px; vertical-align: top; margin:0; padding: 20px 0 0 0; color: #666666; border-top: 1px solid #f0f0f0;" align="center" valign="bottom">Sent by
                                            <a href="https://mynetdata.io/" target="_blank">netdata</a>, the real-time performance and health monitoring, on <code>${host}</code>.
                                        </td>
                                    </tr>
                                    </tbody>
                                </table>
                            </div>
                        </td>
                    </tr>
                    </tbody>
                </table>
            </div>
        </td>
    </tr>
    </tbody>
</table>
</body>
</html>
EOF

send_email <<EOF
To: ${to_email}
Subject: ${host} ${status_message} - ${name//_/ } - ${chart}
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="multipart-boundary"
${email_thread_headers}

This is a MIME-encoded multipart message

--multipart-boundary
${email_plaintext_part}
--multipart-boundary
${email_html_part}
--multipart-boundary--
EOF

fi

SENT_EMAIL=$?

# -----------------------------------------------------------------------------
# let netdata know
for state in "${SENT_EMAIL}" \
	"${SENT_PUSHOVER}" \
	"${SENT_TELEGRAM}" \
	"${SENT_SLACK}" \
	"${SENT_ROCKETCHAT}" \
	"${SENT_ALERTA}" \
	"${SENT_FLOCK}" \
	"${SENT_DISCORD}" \
	"${SENT_TWILIO}" \
	"${SENT_HIPCHAT}" \
	"${SENT_MESSAGEBIRD}" \
	"${SENT_KAVENEGAR}" \
	"${SENT_PUSHBULLET}" \
	"${SENT_KAFKA}" \
	"${SENT_PD}" \
	"${SENT_FLEEP}" \
	"${SENT_PROWL}" \
	"${SENT_CUSTOM}" \
	"${SENT_IRC}" \
	"${SENT_AWSSNS}" \
	"${SENT_SYSLOG}" \
	"${SENT_SMS}" \
	"${SENT_MSTEAM}"; do
	if [ "${state}" -eq 0 ]; then
		# we sent something
		exit 0
	fi
done
# we did not send anything
exit 1
