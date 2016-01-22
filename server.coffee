Db = require 'db'
App = require 'app'
Event = require 'event'
Timer = require 'timer'
Comments = require 'comments'
Shared = require 'shared'

exports.onUpgrade = !->
	log '[onUpgrade()] at '+new Date()

exports.onInstall = (config = {}) !->
	onConfig(config)

exports.onConfig = onConfig = (config) !->
	if config.currency
		result = config.currency
		if result.length is 0
			result = "€"
		else if result.length > 1
			result = result.substr(0, 1)
		Db.shared.set "currency", result
	if config.mode is 'single'
		Db.shared.set 'singleMode', true
		Db.shared.set 'setupFirst', true

# Add or change a transaction
## id = transaction number
## data = {user: <amount>, ...}
exports.client_transaction = (id, data) !->
	# Verify and clean data
	newBy = {}
	total = 0
	for userId, share of data.by
		if (not isNaN(+share)) and +share isnt 0
			newBy[userId] = share
			total += (+share)
	data.by = newBy
	if total isnt data.total
		log "[transaction()] WARNING: total does not match the by section, total="+data.total+" byTotal="+total
		return

	if (isNew = !id)
		id = Db.shared.modify 'transactionId', (v) -> (v||0)+1
		data["created"] = (new Date())/1000
	else
		data["created"] = Db.shared.peek("transactions", id, "created")
		data["updated"] = (new Date())/1000
	data.total = +data.total

	Db.shared.set 'transactions', id, data
	Db.shared.set 'transactions', id, 'creatorId', App.userId()
	# Send notifications
	members = []
	Db.shared.iterate "transactions", id, "for", (user) !->
		members.push user.key()
	Db.shared.iterate "transactions", id, "by", (user) !->
		members.push user.key()
	if isNew
		Event.create
			unit: "transaction"
			text: App.userName()+" added transaction: "+Db.shared.peek("transactions", id, "text")+" ("+formatMoney(Db.shared.peek("transactions", id, "total"))+")"
			include: members
			sender: App.userId()
	else
		Event.create
			unit: "transaction"
			text: App.userName()+" edited transaction: "+Db.shared.peek("transactions", id, "text")+" ("+formatMoney(Db.shared.peek("transactions", id, "total"))+")"
			path: [id]
			include: members
			sender: App.userId()

		# Add system comment
		Comments.post
			legacyStore: id
			u: App.userId()
			s: "edited"

	Timer.cancel 'settleRemind', {}
	allZero = true
	for userId,amount of getBalances()
		if amount isnt 0
			allZero = false
	if not allZero
		Timer.set 1000*60*60*24*7, 'settleRemind', {}  # Week

	# Remove flag that indicates that the user should setup a transaction
	if Db.shared.get('setupFirst')
		settleStart()
		Db.shared.set 'setupFirst', false


# Delete a transaction
exports.client_removeTransaction = (id) !->
	# Remove transaction
	Db.shared.remove("transactions", id)

# Start a settle for all balances
exports.client_settleStart = settleStart = !->
	# Generate required settle transactions
	memberGuilt = {} # id, amount, [names of others]
	negBalances = []
	posBalances = []
	for userId,amount of getBalances()
		if amount > 0
			posBalances.push([userId, amount])
		else if amount < 0
			negBalances.push([userId, amount])
	# Check for equal balance differences
	i = negBalances.length-1
	settles = {}
	while i >= 0
		j = posBalances.length-1
		while j >= 0 and i >= 0
			neg = negBalances[i][1]
			pos = posBalances[j][1]
			if -neg == pos
				identifier = negBalances[i][0] + ":" + posBalances[j][0]
				settles[identifier] = {done: false, amount: pos}
				m = 0|negBalances[i][0]
				memberGuilt[m] = memberGuilt[m]||{amount: 0, others: []}
				memberGuilt[m].amount+=pos
				memberGuilt[m].others.push posBalances[j][0]
				negBalances.splice(i, 1)
				posBalances.splice(j, 1)
				i--
			j--
		i--

	# Create settles for the remaining balances
	while negBalances.length > 0 and posBalances.length > 0
		identifier = negBalances[0][0] + ":" + posBalances[0][0]
		amount = Math.min(Math.abs(negBalances[0][1]), posBalances[0][1])
		settles[identifier] = {done: false, amount: amount}
		m = 0|negBalances[0][0]
		memberGuilt[m] = memberGuilt[m]||{amount: 0, others: []}
		memberGuilt[m].amount+=amount
		memberGuilt[m].others.push posBalances[0][0]
		negBalances[0][1] += amount
		posBalances[0][1] -= amount
		if negBalances[0][1] == 0
			negBalances.shift()
		if posBalances[0][1] == 0
			posBalances.shift()
	# Check for leftovers (should only happen when balances do not add up to 0)
	if negBalances.length > 0
		log "WARNING: leftover negative balances: "+negBalances[0][1]
	if posBalances.length > 0
		log "WARNING: leftover positive balances: "+posBalances[0][1]
	# Print and set the settles
	log "Generated settles: "+JSON.stringify(settles)
	log "Generated memberGuilt: "+JSON.stringify(memberGuilt)
	Db.shared.set 'settle', settles
	# Send notifications
	for member, guilt of memberGuilt
		Event.create
			for: member
			text: "A settle has started. You have to pay " + formatMoney(guilt.amount) + (if guilt.others.length is 1 then (" to " + App.userName(guilt.others[0])) else " in total")
		Timer.set 1000*60*60*24*7, 'reminder', member  # Week

	# Add system comment
	Comments.post
		u: App.userId()
		s: "settleStart"

	# Set reminders
	Timer.cancel 'settleRemind', {}
	# Db.shared.iterate "settle", (settle) !->
	# 	Timer.set 1000*60*60*24*7, 'reminder', {users: settle.key()}  # Week: 1000*60*60*24*7
	Timer.set 1000*60*60*24*7, 'postReminder' # week

exports.postReminder = !->
	# Add system comment
	Comments.post #
		s: "settleRemind"
	Timer.set 1000*60*60*24*7, 'postReminder'

# Triggered when a settle reminder happens
## args.users = key to settle transaction
exports.reminder = (member) ->
	others = 0
	other = ""
	Db.shared.iterate "settle", (settle) !->
		[from,to] = settle.key().split(':')
		if from is member
			others++
			other = to
	return if others is 0
	msg = ""
	if others is 1
		msg = "Reminder: there is an open settle to " + App.userName(other)
	else
		msg = "Reminder: you have " + others + " open settles!"
	log "send reminder", member, ":", msg
	Event.create
		text: msg
		for: [member]
	Timer.set 1000*60*60*24*7, 'reminder', member # week

# Reminder of non-zero balances
exports.settleRemind = (args) ->
	users = []
	balances = getBalances()
	for userId in App.userIds()
		if balances[userId] isnt 0
			users.push userId
	if users.length > 0 and !Db.shared.isHash('settle')
		Event.create
			unit: "settleRemind"
			text: "Reminder: there are balances to settle"
			for: users
		Timer.set 1000*60*60*24*7, 'settleRemind', args # week

# Stop the current settle, or finish when complete
exports.client_settleStop = !->
	members = []
	Db.shared.iterate 'settle', (settle) !->
		[from,to] = settle.key().split(":")
		members.push from
		members.push to
		Timer.cancel 'reminder', {users: settle.key()}
		Timer.cancel 'postReminder'
	# Add system comment
	Comments.post
		u: App.userId()
		s: "settleCancel"
	Event.create
		unit: "settleFinish"
		text: "Settling has been cancelled"
		for: members
	Db.shared.remove 'settle'
	# Timer.set 1000*60*60*24*7, 'settleRemind', {}
	Timer.cancel 'settleRemind', {}

# Sender marks settle as paid
exports.client_settlePayed = (key) !->
	[from,to] = key.split(':')
	return if App.userId() != +from
	done = Db.shared.modify 'settle', key, 'done', (v) -> !v
	if done
		Event.create
			unit: "settlePaid"
			text: App.userName(from)+" paid you "+formatMoney(Db.shared.peek("settle", key, "amount"))+" to settle, please confirm"
			for: [to]

# Receiver marks settle as paid
exports.client_settleDone = (key) !->
	settle = Db.shared.ref 'settle', key
	[from,to] = key.split(':')
	return if (App.userId() != +to and !App.userIsAdmin())
	id = Db.shared.modify 'transactionId', (v) -> (v||0)+1
	transaction = {}
	forData = {}
	forData[to] = settle.peek("amount")
	byData = {}
	byData[from] = settle.peek("amount")
	transaction["creatorId"] = -1
	transaction["for"] = forData
	transaction["by"] = byData
	transaction["type"] = "settle"
	transaction["total"] = settle.peek("amount")
	transaction["created"] = (new Date()/1000)
	Db.shared.set 'transactions', id, transaction
	log "accepted settle:", from, to, App.userId()
	if App.userId() != +to
		Event.create
			unit: "settleDone"
			text: "Admin "+App.userName(App.userId())+" confirmed a "+formatMoney(Db.shared.peek("settle", key, "amount"))+" settle payment"
			for: [from, to]
	else
		Event.create
			unit: "settleDone"
			text: App.userName(to)+" accepted your "+formatMoney(Db.shared.peek("settle", key, "amount"))+" settle payment"
			for: [from]
	Db.shared.remove "settle", key
	# Cancel reminder for this settle
	Timer.cancel 'reminder', {users: key}

	#if this was the last settle
	if Object.keys(Db.shared.get('settle')).length is 0
		log "Settlement is done!"
		# Add system comment
		Comments.post
			u: from
			s: "settleDone"
		Timer.cancel 'postReminder'

# Set account of a user
exports.client_account = (number, name) !->
	Db.shared.set "accounts", App.userId(), number
	Db.shared.set "accountNames", App.userId(), name

formatMoney = (amount) ->
	amount = Math.round(amount)
	currency = "€"
	if Db.shared.get("currency")
		currency = Db.shared.get("currency")
	string = amount/100
	if amount%100 is 0
		string +=".00"
	else if amount%10 is 0
		string += "0"
	return currency+string

capitalizeFirst = (string) ->
	return string.charAt(0).toUpperCase() + string.slice(1)

getBalances = ->
	balances = {}
	for userId in App.userIds()
		balances[userId] = 0
	Db.shared.iterate "transactions", (transaction) !->
		diff = Shared.transactionDiff(transaction.key())
		for userId, amount of diff
			balances[userId] = (balances[userId]||0) + (diff[userId]||0)
	return balances
