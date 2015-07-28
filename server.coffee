Db = require 'db'
Plugin = require 'plugin'
Event = require 'event'
Timer = require 'timer'
Social = require 'social'

exports.onUpgrade = ->
	log '[onUpgrade()] at '+new Date()

	#restoreFromV1()
	#return

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
	# Verify and clean data
	newBy = {}
	total = 0
	for userId, share of data.by
		log "userId="+userId+", share="+share
		if (not isNaN(+share)) and +share isnt 0
			newBy[userId] = share
			total += (+share)
	data.by = newBy
	if total isnt data.total
		log "[transaction()] WARNING: total does not match the by section, total="+data.total+" byTotal="+total
		return

	isNew = false
	if !id
		id = Db.shared.modify 'transactionId', (v) -> (v||0)+1
		isNew = true
		data["created"] = (new Date())/1000
	else
		# Undo previous data on balance
		prevData = Db.shared.get 'transactions', id
		balanceAmong prevData.total, prevData.by, id, true
		balanceAmong prevData.total, prevData.for, id, false
		data["created"] = Db.shared.peek("transactions", id, "created")
		data["updated"] = (new Date())/1000
	data.total = +data.total

	Db.shared.set 'transactions', id, data
	Db.shared.set 'transactions', id, 'creatorId', Plugin.userId()
	balanceAmong data.total, data.by, id, false
	balanceAmong data.total, data.for, id, true
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
		# TODO: specify what has been changed?
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
	Db.shared.iterate "balances", (user) !->
		if user.peek() isnt 0
			allZero = false
	if not allZero
		Timer.set 1000*60*60*24*7, 'settleRemind', {}  # Week: 1000*60*60*24*7


# Delete a transaction
exports.client_removeTransaction = (id) !->
	# TODO: Only by admin? Only by creator?
	transaction = Db.shared.ref("transactions", id)
	# Undo transaction balance changes
	balanceAmong transaction.peek("total"), transaction.peek("by"), id, true
	balanceAmong transaction.peek("total"), transaction.peek("for"), id, false
	# Remove transaction
	Db.shared.remove("transactions", id)

# Process a transaction and update balances
balanceAmong = (total, users, txId = 99, invert) !->
	log "balanceAmong: total="+total+", users="+JSON.stringify(users)+", txId="+txId
	divide = []
	remainder = total
	totalShare = 0
	for userId,amount of users
		if (amount+"").substr(-1) is "%"
			amount = amount+""
			percent = +(amount.substring(0, amount.length-1))
			totalShare += percent
			divide.push userId
		else if (""+amount) is "true"
			divide.push userId
			totalShare += 100
		else
			number = Math.round(+amount*100.0)/100.0
			remainder -= number
			old = Db.shared.peek('balances', userId)
			newValue = Db.shared.modify 'balances', userId, (v) -> (v||0) + (if invert then -1 else 1) * number
			log "userId="+userId+", total="+total+", old="+old+", balance+="+number+", new="+newValue
	#log "total="+total+", totalShare="+totalShare+", remainder="+remainder
	if remainder isnt 0 and divide.length > 0
		lateRemainder = remainder
		while userId = divide.pop()
			raw = users[userId]
			percent = 100
			if (raw+"").substr(-1) is "%"
				raw = raw+""
				percent = +(raw.substring(0, raw.length-1))
			amount = Math.round((remainder*100.0)/totalShare*percent)/100.0
			lateRemainder -= amount
			old = Db.shared.peek('balances', userId)
			newValue = Db.shared.modify 'balances', userId, (v) -> (v||0) + (if invert then -1 else 1) *  amount
			log "userId="+userId+", total="+total+", old="+old+", balance+="+amount+", new="+newValue
			#log "amount="+amount+", remainder="+remainder+", totalShare="+totalShare+", percent="+percent+", lateRemainder="+lateRemainder
		#log "lateRemainder="+lateRemainder
		if lateRemainder isnt 0  # There is something left (probably because of rounding)
			# random user gets (un)lucky
			count = 0
			for userId of users
				count++
			selected = Math.floor(randomFromSeed(txId)*count)
			selected-- if selected is count
			log "count="+count+", transactionNumber="+txId+", selected="+selected+", random="+randomFromSeed(txId)
			counter = 0
			for userId of users
				if selected is counter
					luckyId = userId
				counter++
			Db.shared.modify 'balances', luckyId, (v) ->
				return (v||0) + (if invert then -1 else 1) *  lateRemainder

			###
			count = 0

			for userId of users
				if randomFromSeed(txId) < 1/++count
					luckyId = userId
			Db.shared.modify 'balances', luckyId, (v) ->
				return (v||0) + (if invert then -1 else 1) *  lateRemainder
			###
			log Plugin.userName(luckyId)+" ("+luckyId+") is (un)lucky: "+lateRemainder

# Start a settle for all balances
exports.client_settleStart = !->
	Plugin.assertAdmin()
	# Generate required settle transactions
	negBalances = []
	posBalances = []
	Db.shared.iterate "balances", (user) !->
		log "user="+user.key()+", balance="+user.peek()
		if user.peek() > 0
			log "positive"
			posBalances.push([user.key(), user.peek()])
		else if user.peek() < 0
			log "negative"
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
				log "found the same"
				identifier = negBalances[i][0] + ":" + posBalances[j][0]
				settles[identifier] = {done: 0, amount: pos}
				negBalances.splice(i, 1)
				posBalances.splice(j, 1)
	# Create settles for the remaining balances
	log "posBalances="+posBalances.length + ", negBalances="+negBalances.length
	while negBalances.length > 0 and posBalances.length > 0
		log "found transaction"
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
	for userId in Plugin.userIds()
		if Db.shared.peek("balances", userId) isnt 0
			users.push userId
	Event.create
		unit: "settleRemind"
		text: "Reminder: there are balances to settle"
		include: users
	Timer.set 1000*60*60*24*7, 'settleRemind', args

# Stop the current settle, or finish when complete
exports.client_settleStop = !->
	Plugin.assertAdmin()
	allDone = false
	members = []
	Db.shared.iterate "settle", (settle) !->
		Timer.cancel 'reminder', {users: settle.key()}
		done = settle.peek("done")
		if (done is 2 or done is 3)
			allDone = false
			[from,to] = settle.key().split(':')
			members.push from
			members.push to
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
	if allDone
		Event.create
			unit: "settleFinish"
			text: "Settling has finished, everything has been paid"
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
			text: Plugin.userName(from)+" paid you "+formatMoney(Db.shared.peek("settle", key, "amount"))+" to settle, please confirm"
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

restoreFromV1 = !->
	log "Restoring database of old version"
	Db.shared.iterate (key) !->
		key.remove()
	Db.shared.set Db.backend.peek('v1backup')

importFromV1 = !->
	log "Converting database of old version to new"
	Db.backend.set 'v1backup', Db.shared.peek()
	Db.shared.iterate (key) !->
		key.remove()
	Db.shared.set "balances", "V2"
	Db.backend.iterate "v1backup", "transactions", (transaction) !->
		old = Db.shared.peek('transactionId')
		id = Db.shared.modify 'transactionId', (v) -> (v||0)+1
		log "old transaction: "+transaction.key()+", key from="+old+", to="+id
		#Db.shared.set "transactions", id, id+"-hi"
		Db.shared.set "transactions", id, "creatorId", transaction.peek("creatorId")
		Db.shared.set "transactions", id, "text", transaction.peek("description")
		Db.shared.set "transactions", id, "created", transaction.peek("time")
		total = (transaction.peek("cents")/100.0)
		Db.shared.set "transactions", id, "total", total
		forData = {}
		transaction.iterate "borrowers", (user) !->
			forData[user.key()] = true
		Db.shared.set "transactions", id, "for", forData
		byData = {}
		byData[transaction.peek("lenderId")] = total
		Db.shared.set "transactions", id, "by", byData
		log "byData balanceAmong:"
		balanceAmong total, byData, id, false
		log "forData balanceAmong:"
		balanceAmong total, forData, id, true

# duplicated in client.coffee
randomFromSeed = (seed) ->
	x = Math.sin(seed) * 10000
	return x-Math.floor(x)
