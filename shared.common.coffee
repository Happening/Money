# Distribute cents to users deterministically
exports.remainderDistribution = (users, remainder, transactionNumber) ->
	result = {}
	remaining = Math.round(remainder*100)
	usersArray = []
	for user, dummy of users
		usersArray.push user
	userCount = usersArray.length
	return {} if remaining > userCount or remaining is 0
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
	log "[remainderDistribution] users=", JSON.stringify(users), "usersLeft=", usersArray, ", remainder="+remainder+", transactionNumber="+transactionNumber+", distributed="+transactionNumberOffset/10+", result="+JSON.stringify(result)
	return result

# Pseudo-random number from a seed
randomFromSeed = (seed) ->
	x = Math.sin(seed) * 10000
	x-Math.floor(x)
