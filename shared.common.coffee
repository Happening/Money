Db = require 'db'
Plugin = require 'plugin'

# Distribute cents to users deterministically
exports.remainderDistribution = remainderDistribution = (users, remainder, transactionNumber) ->
	result = {}
	remaining = remainder
	usersArray = []
	for user, dummy of users
		usersArray.push user
	userCount = usersArray.length
	return {} if remaining > userCount or remaining is 0 or remaining < -userCount
	transactionNumberOffset = 0
	while remaining isnt 0
		selected = Math.floor(randomFromSeed(transactionNumber)*userCount)
		selected-- if selected is userCount
		toSet = remaining/Math.abs(remaining)
		result[usersArray[selected]] = (result[usersArray[selected]]||0)+toSet
		usersArray.splice selected, 1
		remaining -= toSet
		transactionNumberOffset += 10
		userCount--
	#log "[remainderDistribution] users=", JSON.stringify(users), "usersLeft=", usersArray, ", remainder="+remainder+", transactionNumber="+transactionNumber+", distributed="+transactionNumberOffset/10+", result="+JSON.stringify(result)
	return result

exports.transactionDiff = transactionDiff = (transactionNumber) ->
	transactionRef = Db.shared.ref "transactions", transactionNumber
	result = balanceAmong transactionRef.get("total"), transactionRef.get("by"), transactionNumber, false
	result = balanceAmong transactionRef.get("total"), transactionRef.get("for"), transactionNumber, true, result
	return result

# Get the diff of a by or for section
balanceAmong = (total, users, txId = 99, invert, startWith = {}) ->
	divide = []
	remainder = total
	totalShare = 0
	result = startWith
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
			number = Math.round(+amount)
			remainder -= number
			result[userId] = (result[userId]||0) + (if invert then -1 else 1) * number
	if remainder isnt 0 and divide.length > 0
		lateRemainder = remainder
		while userId = divide.pop()
			raw = users[userId]
			percent = 100
			if (raw+"").substr(-1) is "%"
				raw = raw+""
				percent = +(raw.substring(0, raw.length-1))
			amount = Math.round((remainder)/totalShare*percent)
			lateRemainder -= amount
			result[userId] = (result[userId]||0) + (if invert then -1 else 1) *  amount
		if lateRemainder isnt 0  # There is something left (probably because of rounding)
			distribution = remainderDistribution users, lateRemainder, txId
			for userId, amount of distribution
				result[userId] = (result[userId]||0) + (if invert then -1 else 1) *  amount
	return result

# Pseudo-random number from a seed
randomFromSeed = (seed) ->
	x = Math.sin(seed) * 10000
	x-Math.floor(x)
