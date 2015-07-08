Db = require 'db'
Plugin = require 'plugin'
Event = require 'event'

exports.onUpgrade = ->
	log '[onUpgrade()] at '+new Date()
	return

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
			log "static"
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

# Stop the current settle, or finish when complete
exports.client_settleStop = !->
	Plugin.assertAdmin()
	allDone = false
	Db.shared.iterate "settle", (settle) !->
		done = settle.get("done")
		if done is 2 or done is 3
			members = []
			Db.shared.iterate "settle", (settle) !->
				[from,to] = settle.key().split(':')
				members.push from
				members.push to
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
	front = Math.floor(amount)
	back = Math.round(amount*100)%100
	if front < 0 and back isnt 0
		"€"+(front+1)+"."+('0'+(back))[-2..]
	else
		"€"+front+"."+('0'+(back))[-2..]

capitalizeFirst = (string) ->
	return string.charAt(0).toUpperCase() + string.slice(1)