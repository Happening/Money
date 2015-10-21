Db = require 'db'
Plugin = require 'plugin'
Event = require 'event'
Timer = require 'timer'
Social = require 'social'
Shared = require 'shared'

exports.onUpgrade = !->
	log '[onUpgrade()] at '+new Date()
	if (Db.shared.get("version")||0) < 2
		log "Upgrading: settle float to int fix and balance changes (marked as U2)"
		Db.shared.set "version", 2

		isFloat = (number) ->
			return number % 1 isnt 0
		convert = (number) ->
			Math.round((number||0)*100)
		if Db.shared.isHash("settle")
			# Fix float settles
			hasFloats = false
			Db.shared.iterate "settle", (settle) !->
				hasFloats = hasFloats || isFloat((settle.get("amount")||0))
			if hasFloats
				Db.shared.iterate "settle", (settle) !->
					log "U2: Settle amount upgraded to integer: oldAmount="+settle.get("amount")
					settle.modify "amount", (v) -> convert(v)

			# Handle confirmed transactions
			Db.shared.iterate "settle", (settle) !->
				done = settle.get("done")
				if done is 2 or done is 3
					[from,to] = settle.key().split(':')
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
					log "U2: added transaction for settle: "+settle.key()+", amount="+settle.peek("amount")
					Db.shared.remove "settle", settle.key()
		# Transaction added by corrupt settle
		Db.shared.iterate "transactions", (transaction) !->
			if transaction.get("type") is "settle" and isFloat(transaction.get("total"))
				# Is an incorrect transaction, do *100
				oldTotal = transaction.get("total")
				transaction.modify "total", (v) -> convert(v)
				transaction.iterate "for", (line) !->
					line.modify (v) -> convert(v)
				transaction.iterate "by", (line) !->
					line.modify (v) -> convert(v)
				log "U2: multiplied settle transaction by 100, id="+transaction.key()+", oldTotal="+oldTotal

		Db.shared.remove "balances"


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
	Db.shared.set 'transactions', id, 'creatorId', Plugin.userId()
	# Send notifications
	members = []
	Db.shared.iterate "transactions", id, "for", (user) !->
		members.push user.key()
	Db.shared.iterate "transactions", id, "by", (user) !->
		members.push user.key()
	if isNew
		Event.create
			unit: "transaction"
			text: Plugin.userName()+" added transaction: "+Db.shared.peek("transactions", id, "text")+" ("+formatMoney(Db.shared.peek("transactions", id, "total"))+")"
			include: members
			sender: Plugin.userId()
	else
		Event.create
			unit: "transaction"
			text: Plugin.userName()+" edited transaction: "+Db.shared.peek("transactions", id, "text")+" ("+formatMoney(Db.shared.peek("transactions", id, "total"))+")"
			path: [id]
			include: members
			sender: Plugin.userId()

		# Add system comment
		Social.customComment id,
			c: "edited the transaction"
			t: Math.round(new Date()/1000)
			u: Plugin.userId()
			system: true

	Timer.cancel 'settleRemind', {}
	allZero = true
	for userId,amount of getBalances()
		if amount isnt 0
			allZero = false
	if not allZero
		Timer.set 1000*60*60*24*7, 'settleRemind', {}  # Week: 1000*60*60*24*7


# Delete a transaction
exports.client_removeTransaction = (id) !->
	# Remove transaction
	Db.shared.remove("transactions", id)


# Start a settle for all balances
exports.client_settleStart = !->
	# Generate required settle transactions
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
	Db.shared.set 'settle', settles
	# Send notifications
	members = []
	Db.shared.iterate "settle", (settle) !->
		[from,to] = settle.key().split(':')
		members.push from
		members.push to
	Event.create
		unit: "settle"
		text: "A settle has started, check your payments"
		include: members
	# Set reminders
	Timer.cancel 'settleRemind', {}
	Db.shared.iterate "settle", (settle) !->
		Timer.set 1000*60*60*24*7, 'reminder', {users: settle.key()}  # Week: 1000*60*60*24*7

# Triggered when a settle reminder happens
## args.users = key to settle transaction
exports.reminder = (args) ->
	[from,to] = args.users.split(':')
	Event.create
		unit: "settlePayRemind"
		text: "Reminder: there is an open settle to "+Plugin.userName(to)
		include: from
	Timer.set 1000*60*60*24*7, 'reminder', args


# Reminder of non-zero balances
exports.settleRemind = (args) ->
	users = []
	balances = getBalances()
	for userId in Plugin.userIds()
		if balances[userId] isnt 0
			users.push userId
	Event.create
		unit: "settleRemind"
		text: "Reminder: there are balances to settle"
		include: users
	Timer.set 1000*60*60*24*7, 'settleRemind', args

# Stop the current settle, or finish when complete
exports.client_settleStop = !->
	members = []
	Db.shared.iterate (settle) !->
		[from,to] = settle.key().split(":")
		members.push from
		members.push to
	Event.create
		unit: "settleFinish"
		text: "Settling has been cancelled"
		include: members
	Db.shared.remove 'settle'


# Sender marks settle as paid
exports.client_settlePayed = (key) !->
	[from,to] = key.split(':')
	return if Plugin.userId() != +from
	done = Db.shared.modify 'settle', key, 'done', (v) -> !v
	if done
		Event.create
			unit: "settlePaid"
			text: Plugin.userName(from)+" paid you "+formatMoney(Db.shared.peek("settle", key, "amount"))+" to settle, please confirm"
			include: [to]

# Receiver marks settle as paid
exports.client_settleDone = (key) !->
	settle = Db.shared.ref 'settle', key
	[from,to] = key.split(':')
	return if (Plugin.userId() != +to and !Plugin.userIsAdmin())
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
	if Plugin.userId() != +to
		Event.create
			unit: "settleDone"
			text: "Admin "+Plugin.userName(Plugin.userId())+" confirmed a "+formatMoney(Db.shared.peek("settle", key, "amount"))+" settle payment"
			include: [from, to]
	else
		Event.create
			unit: "settleDone"
			text: Plugin.userName(to)+" accepted your "+formatMoney(Db.shared.peek("settle", key, "amount"))+" settle payment"
			include: [from]
	Db.shared.remove "settle", key

# Set account of a user
exports.client_account = (number, name) !->
	Db.shared.set "accounts", Plugin.userId(), number
	Db.shared.set "accountNames", Plugin.userId(), name

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
	return currency+(string)

capitalizeFirst = (string) ->
	return string.charAt(0).toUpperCase() + string.slice(1)

getBalances = ->
	balances = {}
	for userId in Plugin.userIds()
		balances[userId] = 0
	Db.shared.iterate "transactions", (transaction) !->
		diff = Shared.transactionDiff(transaction.key())
		for userId, amount of diff
			balances[userId] = (balances[userId]||0) + (diff[userId]||0)
	return balances