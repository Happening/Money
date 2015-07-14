Db = require 'db'
Plugin = require 'plugin'
Event = require 'event'
Timer = require 'timer'

exports.onUpgrade = ->
	log '[onUpgrade()] at '+new Date()
	if not(Db.shared.isHash("balances"))
		log "is old version"
		importFromV1()
	return

exports.onInstall = (config = {}) ->
	Db.shared.set "balances", "V2"
	onConfig(config)

exports.onConfig = onConfig = (config) ->
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
	isNew = false
	if !id
		id = Db.shared.modify 'transactionId', (v) -> (v||0)+1
		isNew = true
		data["created"] = (new Date())/1000
	else
		# Undo previous data on balance
		prevData = Db.shared.get 'transactions', id
		balanceAmong -prevData.total, prevData.by
		balanceAmong prevData.total, prevData.for
		data["created"] = Db.shared.peek("transactions", id, "created")
		data["updated"] = (new Date())/1000
	data.total = +data.total
	
	Db.shared.set 'transactions', id, data	
	Db.shared.set 'transactions', id, 'creatorId', Plugin.userId()
	balanceAmong data.total, data.by
	balanceAmong -data.total, data.for
	# Send notifications
	members = []
	Db.shared.iterate "transactions", id, "for", (user) !->
		members.push user.key()
	Db.shared.iterate "transactions", id, "by", (user) !->
		members.push user.key()
	if isNew
		Event.create
			unit: "transaction"
			text: "New "+formatMoney(Db.shared.peek("transactions", id, "total"))+" transaction created: "+Db.shared.peek("transactions", id, "text")
			include: members
	else
		# TODO: specify what has been changed?
		Event.create
			unit: "transaction"
			text: "Transaction updated: "+Db.shared.peek("transactions", id, "text")
			include: members

# Delete a transaction
exports.client_removeTransaction = (id) !->
	# TODO: Only by admin? Only by creator?
	transaction = Db.shared.ref("transactions", id)
	# Undo transaction balance changes
	balanceAmong -transaction.peek("total"), transaction.peek("by")
	balanceAmong transaction.peek("total"), transaction.peek("for")
	# Remove transaction
	Db.shared.remove("transactions", id)

# Process a transaction and update balances
balanceAmong = (total, users) !->
	divide = []
	remainder = total
	for userId,amount of users
		if (amount+"").endsWith("%")
			amount = amount+""
			percent = +(amount.substring(0, amount.length-1))
			number = Math.round(percent*total)/100.0
			Db.shared.modify 'balances', userId, (v) -> (v||0) + number
			remainder -= number
		else if amount isnt true
			number = +amount
			remainder -= number
		else
			divide.push userId			
	if remainder and divide.length > 0
		amount = Math.round((remainder*100.0)/divide.length)/100.0
		while userId = divide.pop()
			Db.shared.modify 'balances', userId, (v) -> (v||0) + amount
			remainder -= amount
		if remainder  # There is something left (probably because of rounding)
			# random user gets (un)lucky
			count = 0
			for userId of users
				if Math.random() < 1/++count
					luckyId = userId
			Db.shared.modify 'balances', luckyId, (v) -> (v||0) + remainder
			log luckyId+" is (un)lucky: "+remainder

# Start a settle for all balances
exports.client_settleStart = !->
	Plugin.assertAdmin()
	# Generate required settle transactions
	negBalances = []
	posBalances = []
	Db.shared.iterate "balances", (user) !->
		if user.peek() > 0
			posBalances.push([user.key(), user.peek()])
		else if user.peek() < 0
			negBalances.push([user.key(), user.peek()])
	# Check for equal balance differences
	i = negBalances.length
	settles = {}
	while i--
		j = posBalances.length
		while j--
			neg = negBalances[i][1]
			pos = posBalances[j][1]
			if -neg == pos
				identifier = negBalances[i][0] + ":" + posBalances[j][0]
				settles[identifier] = {done: 0, amount: pos}
				negBalances.splice(i, 1)
				posBalances.splice(j, 1)
	# Create settles for the remaining balances
	while negBalances.length > 0 and posBalances.length > 0
		identifier = negBalances[0][0] + ":" + posBalances[0][0]
		amount = Math.min(Math.abs(negBalances[0][1]), posBalances[0][1])
		settles[identifier] = {done: 0, amount: amount}
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
	Db.shared.iterate "settle", (settle) !->
		Timer.set 1000*30, 'reminder', {users: settle.key()}  # Week: 1000*60*60*24*7

# Triggered when a settle reminder happens
## args.users = key to settle transaction
exports.reminder = (args) ->
	[from,to] = args.users.split(':')
	Event.create
		unit: "settleRemind"
		text: "There is an open settle to "+Plugin.userName(to)+"."
		include: from

# Stop the current settle, or finish when complete
exports.client_settleStop = !->
	Plugin.assertAdmin()
	allDone = false
	members = []
	Db.shared.iterate "settle", (settle) !->
		Timer.cancel 'reminder', {users: settle.key()}
		done = settle.peek("done")
		if not(done is 2 or done is 3)
			allDone = false
			[from,to] = settle.key().split(':')
			members.push from
			members.push to
			id = Db.shared.modify 'transactionId', (v) -> (v||0)+1
			transaction = {}
			forData = {}
			forData[to] = true
			byData = {}
			byData[from] = true
			transaction["creatorId"] = -1
			transaction["for"] = forData
			transaction["by"] = byData
			transaction["type"] = "settle"
			transaction["total"] = settle.peek("amount")
			transaction["created"] = (new Date()/1000)
			Db.shared.set 'transactions', id, transaction
	if allDone
		Event.create
			unit: "settleFinish"
			text: "A settle has been finished, everything is paid"
			include: members
	Db.shared.remove 'settle'

# Sender marks settle as paid
exports.client_settlePayed = (key) !->
	[from,to] = key.split(':')
	return if Plugin.userId() != +from
	done = Db.shared.modify 'settle', key, 'done', (v) -> (v&~1) | ((v^1)&1)
	if done is 1 or done is 3
		Event.create
			unit: "settlePaid"
			text: Plugin.userName(from)+" paid "+formatMoney(Db.shared.peek("settle", key, "amount"))+" to you to settle"
			include: [to]

# Receiver marks settle as paid
exports.client_settleDone = (key) !->
	amount = Db.shared.get 'settle', key, 'amount'
	[from,to] = key.split(':')
	return if !amount? or Plugin.userId() != +to
	done = Db.shared.modify 'settle', key, 'done', (v) -> (v&~2) | ((v^2)&2)
	amount = -amount if !(done&2)
	Db.shared.modify 'balances', from, (v) -> (v||0) + amount
	Db.shared.modify 'balances', to, (v) -> (v||0) - amount
	if done is 2 or done is 3
		Event.create
			unit: "settleDone"
			text: Plugin.userName(to)+" accepted your "+formatMoney(Db.shared.peek("settle", key, "amount"))+" settle payment"
			include: [from]


# Set account of a user
exports.client_account = (text) !->
	Db.shared.set 'accounts', Plugin.userId(), text

formatMoney = (amount) ->
	number = amount.toFixed(2)
	currency = "€"
	if Db.shared.get("currency")
		currency = Db.shared.get("currency")
	return currency+number

capitalizeFirst = (string) ->
	return string.charAt(0).toUpperCase() + string.slice(1)


importFromV1 = !->
	Db.shared.set 'x_v1backup', Db.shared.peek()
	Db.shared.iterate (key) !->
		if key.key() isnt 'x_v1backup'
			Db.shared.remove key.key()
	log "Converting database of old version to new"
	Db.shared.iterate "x_v1backup", "transactions", (transaction) !->
		id = Db.shared.modify 'transactionId', (v) -> (v||0)+1
		log "old transaction: "+transaction.key()
		Db.shared.set "transactions", id, "creatorId", transaction.peek("creatorId")
		Db.shared.set "transactions", id, "text", transaction.peek("description")
		Db.shared.set "transactions", id, "created", transaction.peek("time")
		total = (transaction.peek("cents")/100)
		Db.shared.set "transactions", id, "total", total
		forData = {}
		transaction.iterate "borrowers", (user) !->
			forData[user.key()] = true
		Db.shared.set "transactions", id, "for", forData
		byData = {}
		byData[transaction.peek("lenderId")] = true
		Db.shared.set "transactions", id, "by", byData
		balanceAmong total, byData
		balanceAmong -total, forData

