Db = require 'db'
Dom = require 'dom'
Form = require 'form'
Icon = require 'icon'
Modal = require 'modal'
Obs = require 'obs'
Plugin = require 'plugin'
Page = require 'page'
Server = require 'server'
Ui = require 'ui'
{tr} = require 'i18n'
Social = require 'social'
Time = require 'time'
Event = require 'event'
Shared = require 'shared'

exports.render = ->
	req0 = Page.state.get(0)
	if req0 is 'new'
		renderEditOrNew()
		return
	if req0 is 'balances'
		renderBalances()
		return
	if +req0 and Page.state.get(1) is 'edit'
		renderEditOrNew +req0
		return
	if +req0
		renderView +req0
		return

	Event.markRead(["transaction"])
	# Balances
	Dom.section !->
		Dom.div !->
			balance = (Db.shared.get("balances", Plugin.userId())||0)
			Dom.style Box: 'horizontal'
			Dom.div !->
				Dom.text tr("Show all balances")
				Dom.style
					Flex: true
					color: Plugin.colors().highlight
					marginTop: '1px'
			Dom.div !->
				Dom.text "You:"
				Dom.style
					textAlign: 'right'
					margin: '1px 10px 0 0'
			Dom.div !->
				Dom.style
					fontWeight: "bold"
					fontSize: '120%'
					textAlign: 'right'
				stylePositiveNegative(balance)
				Dom.text formatMoney(balance)
		Dom.onTap !->
			Page.nav ['balances']
		Dom.style padding: '16px'

	settleO = Db.shared.ref('settle')
	if settleO.isHash()
		renderSettlePane(settleO)
	else
		total = getTotalBalance()
		Obs.observe !->
			if Math.round(total.get()*100) isnt 0
				Dom.section !->
					Dom.style padding: '16px'
					Dom.div !->
						Dom.style color: Plugin.colors().highlight
						Dom.text tr("Settle balances")
					Dom.div !->
						Dom.style fontSize: '80%', fontWeight: "normal", marginTop: '3px'
						Dom.text tr("Ask people to pay their debts")
					Dom.onTap !->
						Modal.confirm tr("Start settle?"), tr("People with a negative balance are asked to pay up. People with a positive balance need to confirm receipt of the payments."), !->
							Server.call 'settleStart'


	Ui.list !->
		# Add new transaction
		Ui.item !->
			Dom.text "+ Add transaction"
			Dom.style
				color: Plugin.colors().highlight
			Dom.onTap !->
				Page.nav ['new']
		# Latest transactions
		if Db.shared.count("transactions").get() isnt 0
			Db.shared.iterate 'transactions', (tx) !->
				Ui.item !->
					Dom.style padding: '10px 8px 10px 8px'
					Dom.div !->
						Dom.style Box: 'horizontal', width: '100%'
						Dom.div !->
							Dom.style Flex: true
							Event.styleNew tx.get('created')
							if tx.get('type') is 'settle'
								Dom.text tr("Settle payment")
							else
								Dom.text capitalizeFirst(tx.get('text'))
							Dom.style fontWeight: "bold"
							Dom.div !->
								Dom.style fontSize: '80%', fontWeight: "normal", marginTop: '3px'
								byIds = (id for id of tx.get('by'))
								forIds = (id for id of tx.get('for'))
								forText = if tx.get('type') is 'settle' then formatGroup(forIds, false) else tr("%1 person|s", tx.count('for').get())
								Dom.text tr("%1 by %2 for %3", formatMoney(tx.get('total')), formatGroup(byIds, false), forText)

						# Your share
						Dom.div !->
							Box: 'vertical'
							Dom.style textAlign: 'right', paddingLeft: '10px'
							Dom.div !->
								share = calculateShare(tx, Plugin.userId())
								stylePositiveNegative(share)
								Dom.text formatMoney(share)
								if share is 0
									Dom.style color: '#999999'
							# Number of events on the transaction (comments)
							Dom.div !->
								Dom.style margin: '12px -4px 0 0'
								Event.renderBubble [tx.key()]


					Dom.onTap !->
						Page.nav [tx.key()]
			, (tx) -> -tx.key()

renderBalances = !->
	Page.setTitle tr("All balances")
	Ui.list !->
		Dom.h2 tr("Balances")
		renderItem = (userId, balance) !->
			Ui.item !->
				stylePositiveNegative(balance)
				Ui.avatar Plugin.userAvatar(userId),
					onTap: (!-> Plugin.userInfo(userId))
					style: marginRight: "10px"
				Dom.div !->
					Dom.style Flex: true
					Dom.div formatName(userId, true)
				Dom.div !->
					Dom.text formatMoney(balance)
		Db.shared.iterate "balances", (user) !->
			if (!(Plugin.users.get(user.key())?)) and (user.get()||0) is 0
				return
			renderItem user.key(), user.get()
		, (user) ->
			# Sort users with zero balance to the bottom
			number = (Db.shared.get("balances", user.key())||0)
			if number is 0
				return 9007199254740991
			else
				return number
		Plugin.users.iterate (user) !->
			if !(Db.shared.get("balances", user.key())?)
				renderItem user.key(), 0

		settleO = Db.shared.ref('settle')
		if !settleO.isHash()
			total = getTotalBalance()
			Obs.observe !->
				if total.get() isnt 0
					Dom.div !->
						Dom.style textAlign: 'right'
						Ui.button tr("Settle"), !->
							Modal.confirm tr("Start settle?"), tr("People with a negative balance are asked to pay up. People with a positive balance need to confirm receipt of the payments."), !->
								Server.call 'settleStart'
								Page.back()

# Render a transaction
renderView = (txId) !->
	transaction = Db.shared.ref("transactions", txId)
	# Check for incorrect transaction ids
	if !transaction.isHash()
		Ui.emptyText tr("No such transaction")
		return
	Page.setTitle "Transaction"
	Event.showStar tr("this transaction")
	# Set the page actions
	Page.setActions
		icon: 'edit'
		label: "Edit transaction"
		action: !->
			Page.nav [transaction.key(), 'edit']
	# Render paid by items
	Dom.div !->
		Dom.style
			margin: "-8px -8px 8px -8px"
			borderBottom: '2px solid #ccc'
			padding: '8px'
			backgroundColor: "#FFF"
		Dom.div !->
			Dom.style fontSize: "150%"
			if Db.shared.get("transactions", txId, "type") is 'settle'
				Dom.text tr("Settle payment")
			else
				Dom.text transaction.get("text")
		Dom.div !->
			Dom.style fontSize: '80%', margin: "5px 0 5px 0"
			created = Db.shared.get("transactions", txId, "created")
			updated = Db.shared.get("transactions", txId, "updated")
			if created?
				creatorId = Db.shared.get("transactions", txId, "creatorId")
				if creatorId>=0
					Dom.text tr("Added by %1 ", Plugin.userName(creatorId))
				else
					Dom.text tr("Generated by the app ")
				Time.deltaText created
				if updated?
					Dom.text tr(", edited ")
					Time.deltaText updated
		Dom.div !->
			Dom.style marginTop: "15px"
			Dom.h2 tr("Paid by")
			renderBalanceSplitSection(transaction.get("total"), transaction.ref("by"), transaction.key())
		# Render paid for items
		Dom.div !->
			Dom.style marginTop: "15px"
			Dom.h2 tr("Paid for")
			renderBalanceSplitSection(transaction.get("total"), transaction.ref("for"), transaction.key())
	# Comments
	renderSystemComment = (comment) ->
		if comment.get('system')? and comment.get('system')
			Dom.div !->
				Dom.span !->
					Dom.style color: '#999'
					Time.deltaText comment.get('t')
					Dom.text " • "
				Dom.style
					margin: '6px 0px 6px 56px'
					fontSize: '70%'
				Event.styleNew(comment.get('t'))
				Dom.text Plugin.userName(comment.get('u'))+" edited the transaction"
			return true
		return false
	Social.renderComments
		path: [txId]
		content: renderSystemComment

renderBalanceSplitSection = (total, path, transactionNumber) !->
	remainder = Obs.create(total)
	lateRemainder = Obs.create(total)
	totalShare = Obs.create(0)
	usersList = Obs.create {}
	distribution = Obs.create {}
	Obs.observe !->
		path.iterate (user) !->
			userKey = user.key()
			usersList.set userKey, true
			Obs.onClean !->
				usersList.remove userKey
			if (user.get()+"") is "true"
				totalShare.modify((v) -> v+100)
				Obs.onClean !->
					totalShare.modify((v) -> v-100)
			else if (user.get()+"").substr(-1) is "%"
				amount = user.get()+""
				percent = (+(amount.substr(0, amount.length-1)))
				totalShare.modify((v) -> v+percent)
				Obs.onClean !->
					totalShare.modify((v) -> v-percent)
	Obs.observe !->
		distribution.set Shared.remainderDistribution(usersList.peek(), lateRemainder.get(), transactionNumber)
	Obs.observe !->
		path.iterate (user) !->
			amount = user.get()
			number = 0
			suffix = undefined
			if amount is true
				number = Math.round(remainder.get()/totalShare.get()*100)
				lateRemainder.modify((v) -> v-number)
				Obs.onClean !->
					lateRemainder.modify((v) -> v+number)
			else if (amount+"").substr(-1) is "%"
				amount = amount+""
				percent = +(amount.substr(0, amount.length-1))
				number = Math.round(remainder.get()/totalShare.get()*percent)
				lateRemainder.modify((v) -> v-number)
				Obs.onClean !->
					lateRemainder.modify((v) -> v+number)
				suffix = percent+"%"
			else
				number = +amount
				remainder.modify (v) -> v-number
				lateRemainder.modify (v) -> v-number
				suffix = "fixed"
				Obs.onClean !->
					remainder.modify((v) -> v+number)
					lateRemainder.modify((v) -> v+number)
			Ui.item !->
				Ui.avatar Plugin.userAvatar(user.key()),
					onTap: (!-> Plugin.userInfo(user.key()))
					style: marginRight: "10px"
				Dom.div !->
					Dom.style Flex: true
					Dom.div formatName(user.key(), true)
				Dom.div !->
					Dom.style textAlign: 'right'
					Dom.div !->
						Dom.text formatMoney(number+(distribution.get(user.key())||0))
					if suffix isnt undefined
						Dom.div !->
							Dom.style fontSize: '80%'
							Dom.text "("+suffix+")"
		, (amount) ->
			# Sort static on top, then percentage, then remainder
			return getSortValue(amount.get())

# Render a transaction edit page
renderEditOrNew = (editId) !->
	if editId
		edit = Db.shared.ref('transactions', editId)
		if !edit.isHash()
			Ui.emptyText tr("No such transaction")
			return

		Page.setTitle "Edit transaction"
	else
		Page.setTitle "New transaction"

	# Current form total
	totalO = Obs.create 0
	byO = undefined
	forO = undefined
	multiplePaidBy = Obs.create(false)
	# Description and amount input
	Dom.div !->
		# Check if there is an ongoing settle
		if Db.shared.isHash('settle')
			Dom.div !->
				Dom.style
					margin: '0 0 8px'
					background: '#888'
					color: '#fff'
					fontSize: '80%'
					padding: '8px'
					fontStyle: 'italic'
				Dom.text tr("There is an ongoing settle. ")
				if editId
					Dom.text tr("It will not include changes to this transaction.")
				else
					Dom.text tr("It will not include new transactions.")


		Dom.style
			margin: "-8px -8px 8px -8px"
			borderBottom: '2px solid #ccc'
			padding: '8px'
			backgroundColor: "#FFF"
		Dom.div !->
			Dom.style Box: 'top'
			Dom.div !->
				Dom.style Flex: true
				defaultValue = undefined
				if Db.shared.get("transactions", editId, "type") is 'settle'
					defaultValue = "Settle payment"
				else if edit
					defaultValue = edit.get('text')
				Form.input
					name: 'text'
					value: defaultValue
					text: tr("Description")
		Dom.div !->
			Dom.style fontSize: '80%'
			created = Db.shared.get("transactions", editId, "created")
			updated = Db.shared.get("transactions", editId, "updated")
			if created?
				creatorId = Db.shared.get("transactions", editId, "creatorId")
				if creatorId>=0
					Dom.text tr("Added by %1 ", Plugin.userName(creatorId))
				else
					Dom.text tr("Generated by the app ")
				Time.deltaText created
				if updated?
					Dom.text tr(", last edited ")
					Time.deltaText updated
			# No amount entered	
			Form.condition (values) ->
				if (not (values.text?)) or values.text.length < 1
					return tr("Enter a description")

		Dom.div !->
			Dom.style marginTop: '20px'
		Dom.h2 tr("Paid by")
		byO = Obs.create {}
		if edit
			byO.set edit.get('by')
		else
			byO.set Plugin.userId(), 0
		multiplePaidBy.set(byO.count().peek() > 1)
		# Set the total
		Obs.observe !->
			byO.iterate (user) !->
				oldValue = parseInt(user.get())
				totalO.modify((v) -> v + oldValue)
				Obs.onClean !->
					totalO.modify((v) -> v - oldValue)
		# Save data in pagestate
		[handleChange] = Form.makeInput
			name: 'by'
			value: byO.peek()
		Obs.observe !->
			handleChange byO.get()
		# Render page
		Obs.observe !->
			if not multiplePaidBy.get()
				Ui.item !->
					userKey = ""
					byO.iterate (user) !->
						userKey = user.key()
					Ui.avatar Plugin.userAvatar(userKey),
						onTap: (!-> Plugin.userInfo(userKey))
						style: marginRight: "10px"
					Dom.div !->
						Dom.style Flex: true
						Dom.div formatName(userKey, true)
					Dom.div !->
						currency = "€"
						if Db.shared.get("currency")
							currency = Db.shared.get("currency")
						Dom.text currency
						Dom.style
							margin: '-3px 5px 0 0'
							fontSize: '21px'
					inputField = undefined
					centField = undefined
					Dom.div !->
						Dom.style width: '80px', margin: '-20px 0 -20px 0'
						inputField = Form.input
							name: 'paidby'
							type: 'number'
							text: '0'
							inScope: !->
								Dom.style textAlign: 'right'
							onChange: (v) !->
								if v and inputField and centField
									result = wholeAndCentToCents(inputField.value(), centField.value())
									if !isNaN(result)
										byO.set(userKey, result)
						if byO.peek(userKey)
							inputField.value (byO.peek(userKey) - byO.peek(userKey)%100)/100
						else
							inputField.value null
					Dom.div !->
						Dom.style
							width: '10px'
							fontSize: '175%'
							padding: '12px 0 0 5px'
							margin: '-20px 0 -20px 0'
						Dom.text ","
					Dom.div !->
						Dom.style width: '50px', margin: '-20px 0 -20px 0'
						centField = Form.input
							name: 'paidby2'
							type: 'number'
							text: '00'
							onChange: (v) !->
								if v<0
									centField.value(0)
								if v and inputField and centField
									result = wholeAndCentToCents(inputField.value(), centField.value())
									if !isNaN(result)
										byO.set(userKey, result)
						if (b = byO.peek(userKey)) and (mod = b%100) isnt 0
							centField.value mod
						else
							centField.value null
					Dom.on 'keydown', (evt) !->
						if evt.getKeyCode() in [188,190] # comma and dot
							centField.focus()
							centField.select()
							evt.kill()
					,true
			else
				# Set form input
				Obs.observe !->
					Dom.div !->
						Dom.style margin: '5px -5px 0 -5px'
						Plugin.users.iterate (user) !->
							amount = byO.get(user.key())
							number = 0
							suffix = undefined
							if amount
								number = +amount
							Dom.div !-> # Aligning div
								Dom.style
									display: 'inline-block'
									padding: '5px'
									boxSizing: 'border-box'
								items = 2
								while (Page.width()-16)/items > 180
									items++
								items--
								Dom.style width: 100/items+"%"
								Dom.div !-> # Bock div
									Dom.style
										backgroundColor: '#f2f2f2'
										padding: '5px'
										Box: 'horizontal'
										_borderRadius: '2px'
										border: '1px solid #e0e0e0'
									Dom.cls 'selectBlock'
									Dom.onTap
										cb: !->
											value = undefined
											oldValue = undefined
											update = Obs.create(false)
											Obs.observe !->
												update.get()
												if oldValue?
													number = +oldValue
													if (not (isNaN(number)))
														if number is 0
															byO.remove user.key()
														else
															byO.set user.key(), number
													else
														Modal.show "Incorrect input: \""+oldValue+"\", use a number"
												# Do something
											Modal.show tr("Amount paid by %1?", formatName(user.key())), !->
												Dom.div !->
													Dom.style Box: "horizontal"
													Dom.div !->
														currency = "€"
														if Db.shared.get("currency")
															currency = Db.shared.get("currency")
														Dom.text currency
														Dom.style
															margin: '20px 5px 0px 0px'
															fontSize: '21px'
													inputField = undefined
													centField = undefined
													Dom.div !->
														Dom.style width: '80px'
														inputField = Form.input
															name: 'paidby'
															type: 'number'
															text: '0'
															inScope: !->
																Dom.style textAlign: 'right'
															onChange: (v) !->
																if v and inputField and centField
																	oldValue = value
																	value = wholeAndCentToCents(inputField.value(), centField.value())
														if byO.peek(user.key())
															inputField.value (byO.peek(user.key()) - (byO.peek(user.key())%100))/100
														else
															inputField.value null
													Dom.div !->
														Dom.style
															width: '10px'
															fontSize: '175%'
															padding: '23px 0 0 4px'
														Dom.text ","
													Dom.div !->
														Dom.style width: '50px'
														centField = Form.input
															name: 'paidby2'
															type: 'number'
															text: '00'
															onChange: (v) !->
																return if not centField?
																if v<0
																	centField.value(0)
																if inputField
																	oldValue = value
																	value = wholeAndCentToCents(inputField.value(), centField.value())
														if byO.peek(user.key()) and (mod = byO.peek(user.key())%100) isnt 0
															centField.value mod
														else
															centField.value null
													Dom.on 'keydown', (evt) !->
														if evt.getKeyCode() in [188,190] # comma and dot
															centField.focus()
															centField.select()
															evt.kill()
													,true
											, (value) !->
												if value isnt null and value isnt undefined and value is 'ok'
													update.set(true)
											, ['ok', "Ok", 'cancel', "Cancel"]
									Dom.style
										fontWeight: if amount then 'bold' else ''
									Ui.avatar Plugin.userAvatar(user.key()), style: marginRight: "10px"
									Dom.div !->
										Dom.style
											Flex: true
										Dom.div !->
											Dom.style
												Flex: true
												overflow: 'hidden'
												textOverflow: 'ellipsis'
												whiteSpace: 'nowrap'
												marginTop: '10px'
											if amount
												Dom.style marginTop: "0"
											Dom.text formatName(user.key(), true)
										if amount
											Dom.div !->
												Dom.style Box: 'horizontal'
												Dom.div !->
													Dom.style Flex: true
													Dom.text formatMoney(number)
												Dom.div !->
													Icon.render
														data: 'good2'
														size: 20
														color: '#080'

		Obs.observe !->
			if not multiplePaidBy.get() and Plugin.users.count().get() > 1
				Dom.div !->
					Dom.style
						textAlign: 'center'
						color: Plugin.colors().highlight
						fontSize: "80%"
						padding: "7px"
						margin: "0 0 -8px 0"
					Dom.text tr("Add other(s)")
					Dom.onTap !->
						multiplePaidBy.set(true)

		Dom.div !->
			Dom.style marginTop: '20px'
		Dom.h2 tr("Paid for")
		# Setup remainder
		remainder = Obs.create(0)
		lateRemainder = Obs.create(0)
		Obs.observe !->
			oldTotal = totalO.peek()
			remainder.modify((v)->v+totalO.get())
			lateRemainder.modify((v)->v+totalO.get())
			Obs.onClean !->
				remainder.modify((v)->v-oldTotal)
				lateRemainder.modify((v)->v-oldTotal)
		# Setup for
		forO = Obs.create {}
		if edit
			forO.set edit.get('for')
		[handleChange] = Form.makeInput
			name: 'for'
			value: forO.peek()
		Obs.observe !->
			handleChange forO.get()
		# Setup totalshare
		totalShare = Obs.create 0
		usersList = Obs.create {}
		distribution = Obs.create {}
		Obs.observe !->
			transactionNumber = (Db.shared.get('transactionId')||0)+1
			transactionNumber = editId if editId
			distribution.set Shared.remainderDistribution(usersList.peek(), lateRemainder.get(), transactionNumber)
		# Select/deselect all button
		Obs.observe !->
			users = Plugin.users.count().get()
			selected = forO.count().get()
			Dom.div !->
				Dom.text "Select all" if selected < users
				Dom.text "Deselect all" if selected is users
				Dom.style
					float: 'right'
					margin: '-34px -8px -20px 0'
					padding: '9px 8px 2px 8px'
					color: Plugin.colors().highlight
					fontSize: '80%'
				Dom.onTap !->
					if selected < users
						Plugin.users.iterate (user) !->
							if forO.peek(user.key()) is undefined
								forO.set(user.key(), true)
					else
						forO.set {}
		# Render page
		Obs.observe !->
			Dom.div !->
				Dom.style margin: '5px -5px 0 -5px', _userSelect: 'none'
				Plugin.users.iterate (user) !->
					amount = forO.get(user.key())
					number = Obs.create 0
					suffix = undefined
					Obs.observe !->
						if amount
							usersList.set user.key(), true
							Obs.onClean !->
								usersList.remove user.key()
							if (amount+"") is "true"
								totalShare.modify((v) -> v+100)
								Obs.onClean !->
									totalShare.modify((v) -> v-100)
								Obs.observe !->
									currentNumber = Math.round((remainder.get())/totalShare.get()*100)
									number.set(currentNumber)
									lateRemainder.modify((v) -> v-currentNumber)
									Obs.onClean !->
										lateRemainder.modify((v) -> v+currentNumber)
							else if (amount+"").substr(-1) is "%"
								amount = amount+""
								percent = +(amount.substr(0, amount.length-1))
								totalShare.modify((v) -> v+percent)
								Obs.onClean !->
									totalShare.modify((v) -> v-percent)
								Obs.observe !->
									currentNumber = Math.round((remainder.get())/totalShare.get()*percent)
									number.set(currentNumber)
									lateRemainder.modify((v) -> v-currentNumber)
									Obs.onClean !->
										lateRemainder.modify((v) -> v+currentNumber)
								suffix = percent+"%"
							else
								number.set(+amount)
								Obs.observe !->
									remainder.modify((v) -> v-number.get())
									lateRemainder.modify((v) -> v-number.get())
									Obs.onClean !->
										remainder.modify((v) -> v+number.get())
										lateRemainder.modify((v) -> v+number.get())
								suffix = "fixed"
					Dom.div !-> # Aligning div
						Dom.style
							display: 'inline-block'
							padding: '5px'
							boxSizing: 'border-box'
						items = 2
						while (Page.width()-16)/items > 180
							items++
						items--
						Dom.style width: 100/items+"%"
						Dom.div !-> # Bock div
							Dom.style
								backgroundColor: '#f2f2f2'
								padding: '5px'
								Box: 'horizontal'
								_borderRadius: '2px'
								border: '1px solid #e0e0e0'
							Dom.cls 'selectBlock'
							Dom.onTap
								cb: !->
									if amount
										forO.set(user.key(), null)
									else
										forO.set(user.key(), true)
								longTap: !->
									value = undefined
									oldValue = undefined
									update = Obs.create(false)
									Obs.observe !->
										update.get()
										if value?
											v = value
											amount = +v
											if (v+"").substr(-1) is "%"
												percent = +((v+"").substr(0, v.length-1))
												if isNaN(percent)
													Modal.show "Incorrect percentage: \""+v+"\""
													return
												if percent < 0
													Modal.show "Percentage needs to be a positive number"
													return
												else
													if percent is 0
														forO.remove user.key()
													else
														forO.set user.key(), v
											else if not isNaN(+oldValue)
												amount = +oldValue
												if amount is 0
													forO.remove user.key()
												else
													forO.set user.key(), amount
											else
												Modal.show "Please enter a number"
									Modal.show tr("Amount paid for %1?", formatName(user.key())), !->
										procentual = Obs.create (forO.peek(user.key())+"").substr(-1) is "%"
										Obs.observe !->
											if procentual.get()
												Dom.div !->
													Dom.style Box: 'horizontal'
													Dom.div !->
														Dom.style width: '80px'
														defaultValue = undefined
														if (forO.peek(user.key())+"").substr(-1) is "%"
															defaultValue = (forO.peek(user.key())+"").substr(0, (forO.peek(user.key())+"").length-1)
														inputField = Form.input
															name: 'paidForPercent'+user.key()
															text: '100'
															value: defaultValue
															type: 'number'
															onChange: (v) ->
																if v
																	value = v+"%"
																return
													Dom.div !->
														Dom.style
															margin: '20px 5px 0px 0px'
															fontSize: '21px'
														Dom.text "%"
											else
												Dom.div !->
													Dom.style Box: "horizontal"
													Dom.div !->
														currency = "€"
														if Db.shared.get("currency")
															currency = Db.shared.get("currency")
														Dom.text currency
														Dom.style
															margin: '20px 5px 0px 0px'
															fontSize: '21px'
													inputField = undefined
													centField = undefined
													Dom.div !->
														Dom.style width: '80px'
														inputField = Form.input
															name: 'paidby'
															type: 'number'
															text: '0'
															inScope: !->
																Dom.style textAlign: 'right'
															onChange: (v) !->
																if v and inputField and centField
																	oldValue = value
																	value = wholeAndCentToCents(inputField.value(), centField.value())
														if forO.peek(user.key()) and (forO.peek(user.key())+"") isnt "true"
															inputField.value (forO.peek(user.key()) - (forO.peek(user.key())%100))/100
														else
															inputField.value null
													Dom.div !->
														Dom.style
															width: '10px'
															fontSize: '175%'
															padding: '23px 0 0 4px'
														Dom.text ","
													Dom.div !->
														Dom.style width: '50px'
														centField = Form.input
															name: 'paidby2'
															type: 'number'
															text: '00'
															onChange: (v) !->
																if v<0
																	centField.value(0)
																if inputField? and centField?
																	oldValue = value
																	value = wholeAndCentToCents(inputField.value(), centField.value())
														if forO.peek(user.key()) and forO.peek(user.key())%100 isnt 0
															centField = (byO.peek(user.key())%100)
														else
															centField.value null
													Dom.on 'keydown', (evt) !->
														if evt.getKeyCode() in [188,190] # comma and dot
															centField.focus()
															centField.select()
															evt.kill()
													,true
										Dom.br()
										Dom.div !->
											Dom.style
												display: 'inline-block'
												color: Plugin.colors().highlight
												padding: "5px"
												margin: "0 -5px 0 -5px"
											if procentual.get()
												Dom.style fontWeight: 'normal'
											else
												Dom.style fontWeight: 'bold'
											Dom.text "Fixed amount"
											Dom.onTap !->
												procentual.set false
										Dom.text " | "
										Dom.div !->
											Dom.style
												display: 'inline-block'
												color: Plugin.colors().highlight
												padding: "5px"
												margin: "0 -5px 0 -5px"
											if !procentual.get()
												Dom.style fontWeight: 'normal'
											else
												Dom.style fontWeight: 'bold'
											Dom.text "Percentage"
											Dom.onTap !->
												procentual.set true
									, (value) !->
										if value and value is 'ok'
											update.set(true)
									, ['cancel', "Cancel", 'ok', "Ok"]
							Dom.style
								fontWeight: if amount then 'bold' else ''
								clear: 'both'
							Ui.avatar Plugin.userAvatar(user.key()), style: marginRight: "10px"
							Dom.div !->
								Dom.style
									Flex: true
								Dom.div !->
									Dom.style
										Flex: true
										overflow: 'hidden'
										textOverflow: 'ellipsis'
										whiteSpace: 'nowrap'
										marginTop: '10px'
									if amount
										Dom.style marginTop: "0"
									Dom.text formatName(user.key(), true)
								if amount
									Dom.div !->
										Dom.style Box: 'horizontal'
										Dom.div !->
											Dom.style Flex: true
											Dom.text formatMoney(number.get()+(distribution.get(user.key())||0))
											Dom.style
												fontWeight: 'normal'
												fontSize: '90%'
											if suffix isnt undefined
												Dom.div !->
													Dom.style
														fontWeight: 'normal'
														fontSize: '80%'
														display: 'inline-block'
														marginLeft: "5px"
													Dom.text "("+suffix+")"
										Dom.div !->
											Icon.render
												data: 'good2'
												size: 20
												color: '#080'
		Form.condition () ->
			if totalO.peek() is 0
				text = "Total sum cannot be zero"
				if Db.shared.peek("transactions", editId)?
					text += " (remove it instead)"
				return tr(text)

			divide = []
			remainderTemp = totalO.peek()
			completeShare = 0
			for userId,amount of forO.peek()
				if (amount+"").substr(-1) is "%"
					amount = amount+""
					percent = +(amount.substring(0, amount.length-1))
					completeShare += percent
					divide.push userId
				else if (""+amount) is "true"
					divide.push userId
					completeShare += 100
				else
					number = +amount
					amount = Math.round(amount*100.0)/100.0
					remainderTemp -= amount
			if remainderTemp isnt 0 and divide.length > 0
				while userId = divide.pop()
					raw = forO.peek(userId)
					percent = 100
					if (raw+"").substr(-1) is "%"
						raw = raw+""
						percent = +(raw.substring(0, raw.length-1))
					amount = Math.round((remainderTemp*100.0)/completeShare*percent)/100.0
				remainderTemp = 0
			if remainderTemp isnt 0
				return tr("Paid by and paid for do not add up")
	Dom.div !->
		Dom.style
			textAlign: 'center'
			fontStyle: 'italic'
			padding: '3px'
			color: '#aaa'
			fontSize: '85%'
		Dom.text tr("Hint: long-tap on a user to set a specific amount or percentage")

	if Db.shared.peek("transactions", editId)?
		Page.setActions
			icon: 'trash'
			label: "Remove transaction"
			action: !->
				Modal.confirm "Remove transaction",
					"Are you sure you want to remove this transaction?",
					!->
						Server.call 'removeTransaction', editId
						# Back to the main page
						Page.back()
						Page.back()

	Form.setPageSubmit (values) !->
		Page.up()
		result = {}
		result['total'] = totalO.peek()
		result['by'] = byO.peek()
		result['for'] = forO.peek()
		result['text'] = values.text
		Server.call 'transaction', editId, result

# Sort static on top, then percentage, then remainder, then undefined
getSortValue = (key) ->
	if (key+"").substr(-1) is "%"
		return 0
	else if (key+"") is "true"
		return 1
	else if (key is undefined or not (key?))
		return 10
	else
		return -1

renderSettlePane = (settleO) !->
	Ui.list !->
		Dom.h2 tr("Settle")
		Dom.div !->
			Dom.style
				Flex: true
				margin: '8px 0 4px 0'
				background: '#888'
				color: '#fff'
				fontSize: '80%'
				padding: '8px'
				fontStyle: 'italic'

			if account = Db.shared.get('accounts', Plugin.userId())
				Dom.text tr("Your account number: %1", account)
			else
				Dom.text tr("Tap to setup your account number")
			Dom.onTap !->
				Modal.prompt tr("Your account number"), (text) !->
					Server.sync 'account', text, !->
						Db.shared.set 'account', Plugin.userId(), text
		settleO.iterate (tx) !->
			Ui.item !->
				[from,to] = tx.key().split(':')
				done = tx.get('done')
				amount = tx.get('amount')
				Icon.render
					data: 'good2'
					color: if done&2 then '#080' else if done&1 then '#777' else '#ccc'
					style: {marginRight: '10px'}
				statusText = undefined
				statusBold = false
				confirmText = undefined
				isTo = +to is Plugin.userId()
				isFrom = +from is Plugin.userId()
				# Determine status text
				if done&2
					statusText = tr("%1 received %2 from %3", formatName(to,true), formatMoney(amount), formatName(from))
				else
					if done&1
						statusBold = isTo
						statusText = tr("%1 paid %2 to %3", formatName(from,true), formatMoney(amount), formatName(to))
					else
						statusBold = isFrom || isTo
						statusText = tr("%1 should pay %2 to %3", formatName(from,true), formatMoney(amount), formatName(to))
				# Determine action text and tap action
				paidToggle = !->
					Server.sync 'settlePayed', tx.key(), !->
						result = (done&~1) | ((done^1)&1)
						tx.set 'done', result
				doneToggle = !->
					Server.sync 'settleDone', tx.key(), !->
						result = (done&~2) | ((done^2)&2)
						tx.set 'done', result
				confirmAdminCancel = !->
					Dom.onTap !->
						Modal.confirm tr("Unconfirm as admin?")
							, tr("This will unconfirm receipt of payment by %1", formatName(to))
							, !->
								doneToggle()
				confirmAdminDone = !->
					Dom.onTap !->
						Modal.confirm tr("Confirm as admin?")
							, tr("This will confirm receipt of payment by %1", formatName(to))
							, !->
								doneToggle()
				if !isTo and !isFrom
					if Plugin.userIsAdmin()
						if done&2
							confirmText = tr("Tap to unconfirm this payment as admin")
							confirmAdminCancel()
						else
							confirmText = tr("Tap to confirm this payment as admin")
							confirmAdminDone()
				else if !isTo and isFrom
					if !(done&2)
						if done&1 # sender confirmed
							if Plugin.userIsAdmin()
								confirmText = tr("Waiting for confirmation by %1", formatName(to))
								Dom.onTap !->
									Modal.show tr("(Un)confirm payment?")
										, !->
											Dom.text tr("Do you want to unconfirm that you paid, or (as admin) confirm receipt of payment by %1?", formatName(to))
										, (value) !->
											if value is 'removeSend'
												paidToggle()
											else if value is 'confirmPay'
												doneToggle()
										, ['cancel', "Cancel", 'removeSend', "Unconfirm", 'confirmPay', "Confirm"]
							else
								confirmText = tr("Waiting for confirmation by %1, tap to cancel", formatName(to))
								Dom.onTap !->
									paidToggle()
						else
							if account = Db.shared.get('accounts', to)
								accountTxt = if !!Form.clipboard and Form.clipboard() then tr("%1 (long press to copy)", account) else tr("%1", account)
								confirmText = tr("Account: %1. Tap to confirm your payment to %2.", accountTxt, formatName(to))
							else
								confirmText = tr("Account info missing. Tap to confirm your payment to %1.", formatName(to))
							Dom.onTap
								cb: !-> paidToggle()
								longTap: !->
									if account and !!Form.clipboard and (clipboard = Form.clipboard())
										clipboard(account)
										require('toast').show tr("Account copied to clipboard")
					else if Plugin.userIsAdmin()
						confirmText = tr("Tap to unconfirm as admin")
						confirmAdminCancel()
				else if isTo and !isFrom
					if done&2 # receiver confirmed
						confirmText = tr("Tap to unconfirm")
					else
						confirmText = tr("Tap to confirm receipt of payment")
					Dom.onTap !->
						doneToggle()
				else
					# Should never occur (incorrect settle)
				Dom.div !->
					Dom.style fontWeight: (if statusBold then 'bold' else ''), Flex: true
					Dom.text statusText
					if confirmText?
						Dom.div !->
							Dom.style fontSize: '80%'
							Dom.text confirmText

				###
					if done&2
						Dom.text tr("%1 received %2 from %3", formatName(to,true), formatMoney(amount), formatName(from))
					else
						if done&1
							Dom.text tr("%1 paid %2 to %3", formatName(from,true), formatMoney(amount), formatName(to))
						else
							Dom.span !->
								Dom.style
									fontWeight: if +from is Plugin.userId() then 'bold' else ''
								Dom.text tr("%1 should pay %2 to %3", formatName(from,true), formatMoney(amount), formatName(to))

						Dom.div !->
							Dom.style
								fontSize: '80%'
								fontWeight: if +to is Plugin.userId() then 'bold' else ''

							if +to is Plugin.userId()
								Dom.text tr("Tap to confirm receipt of payment")
							else if Plugin.userIsAdmin(+to)
								Dom.text tr("Tap to confirm as admin")
							else if done&1
								Dom.text tr("Waiting for %1 to confirm payment", formatName(to))
							else if account = Db.shared.get('accounts', to)
								Dom.text tr("Account: %1", account)
							else
								Dom.text tr("%1 has not entered account info", formatName(to))

				if +from is Plugin.userId() and !(done&2)
					Dom.onTap !->
						Server.sync 'settlePayed', tx.key(), !->
							tx.set 'done', (done&~1) | ((done^1)&1)

				else if +to is Plugin.userId()
					Dom.onTap !->
						Server.sync 'settleDone', tx.key(), !->
							tx.set 'done', (done&~2) | ((done^2)&2)
				###

		Dom.div !->
			Dom.style textAlign: 'right'
			complete = true
			sentButNotReceived = false
			for k,v of settleO.get()
				if v.done&1 and !(v.done&2)
					sentButNotReceived = true
				if !(v.done&2)
					complete = false

			if complete
				Ui.button tr("Finish"), !->
					Modal.confirm tr("Finish settle?"), tr("The settle payments will be added to the list of transactions, concluding the settle"), !->
						Server.call 'settleStop'
			else if Plugin.userIsAdmin() # serverside this case will not be checked, ah well --Jelmer
				Ui.button tr("Postpone"), !->
					if sentButNotReceived
						Modal.show tr("Postpone not allowed"), tr("Please (un)confirm receipt of sent payments (dark gray checkmarks) before postponing the settle")
					else
						Modal.confirm tr("Postpone settle?"), !->
							Dom.userText tr("Payments that have been confirmed by the receiver will be saved")
						, !-> Server.call 'settleStop'


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

formatName = (userId, capitalize) ->
	if +userId != Plugin.userId()
		Plugin.userName(userId)
	else if capitalize
		tr("You")
	else
		tr("you")

formatGroup = (userIds, capitalize) ->
	if userIds.length > 3
		userIds[0...3].map(formatName).join(', ') + ' and ' + (userIds.length-3) + ' others'
	else if userIds.length > 1
		userIds[0...userIds.length-1].map(formatName).join(', ') + ' and ' + Plugin.userName(userIds[userIds.length-1])
	else if userIds.length is 1
		formatName(userIds[0], capitalize)

selectUser = (cb) !->
	require('modal').show tr("Select user"), !->
		Dom.style width: '80%'
		Dom.div !->
			Dom.style
				maxHeight: '40%'
				backgroundColor: '#eee'
				margin: '-12px'
			Dom.overflow()
			Plugin.users.iterate (user) !->
				Ui.item !->
					Ui.avatar user.get('avatar')
					Dom.text user.get('name')
					Dom.onTap !->
						cb user.key()
						Modal.remove()
			, (user) ->
				+user.key()
	, false, ['cancel', tr("Cancel")]


exports.renderSettings = !->
	Dom.text "Select the currency symbol you want to use:"
	Dom.br()
	currencyInput = null
	Dom.div !->
		Dom.style display: 'inline-block', marginRight: "15px", width: "25px"
		text = '€'
		if Db.shared
			if Db.shared.get("currency")
				text = Db.shared.get("currency")
		currencyInput = Form.input
			name: 'currency'
			text: text
	renderCurrency = (value) !->
		Ui.button !->
			Dom.text value
			Dom.style
				width: "20px"
				fontSize: "125%"
				textAlign: "center"
				padding: "4px 6px"
		, !->
			currencyInput.value(value)
	renderCurrency("€")
	renderCurrency("$")
	renderCurrency("£")


calculateShare = (transaction, id) ->
	calculatePart = (section, total, id) ->
		divide = []
		remainder = total
		totalShare = 0
		for userId,amount of section.peek()
			if (amount+"").substr(-1) is "%"
				amount = amount+""
				percent = +(amount.substring(0, amount.length-1))
				totalShare += percent
				divide.push userId
			else if (""+amount) is "true"
				divide.push userId
				totalShare += 100
			else
				number = +amount
				remainder -= amount
				if (userId+"") is (id+"")
					return amount
		result = 0
		if remainder isnt 0 and divide.length > 0
			lateRemainder = remainder
			while userId = divide.pop()
				raw = section.peek(userId)
				percent = 100
				if (raw+"").substr(-1) is "%"
					raw = raw+""
					percent = +(raw.substring(0, raw.length-1))
				amount = Math.round(remainder/totalShare*percent)
				lateRemainder -= amount
				if (userId+"") is (id+"")
					result = amount

			if lateRemainder isnt 0  # There is something left
				distribution = Shared.remainderDistribution section.peek(), lateRemainder, transaction.key()
				result += (distribution[id]||0)

		return result
	byAmount = calculatePart(transaction.ref('by'), transaction.get('total'), id)
	forAmount = calculatePart(transaction.ref('for'), transaction.get('total'), id)
	result = byAmount - forAmount
	return result

stylePositiveNegative = (amount) !->
	if amount > 0
		Dom.style color: "#080"
	else if amount < 0
		Dom.style color: "#E41B1B"

capitalizeFirst = (string) ->
	return string.charAt(0).toUpperCase() + string.slice(1)

getTotalBalance = ->
	total = Obs.create 0
	Db.shared.iterate "balances", (user) !->
		value = user.get()
		total.modify((v) -> (v||0)+Math.abs(value))
		Obs.onClean !->
			total.modify((v) -> (v||0)-Math.abs(value))
	total

wholeAndCentToCents = (whole, cent) ->
	whole = +(whole||0)
	cent = +(cent||0)
	if cent > 0 and cent < 10
		cent *=10
	return whole*100 + cent

Dom.css
	'.selected:not(.tap)':
		background: '#f0f0f0'
	'.selectBlock:hover':
		background: '#e0e0e0 !important'
		border: '1px solid #d0d0d0 !important'
