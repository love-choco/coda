# Glossary

####Account

Coda uses accounts to track each public key's state. This is distinct from Bitcoin's UTXO model of maintaining ledger state.

####Block

A set of transactions and consensus information that extend the state of the network. Includes a proof that the current state of the network is fully valid.

####Blockchain

The data structure that is used in a cryptocurrency to maintain a shared state of all accounts in the network. 

####Block Confirmations

The number of blocks added after the reference block. As the number of confirmations increases, the likelihood of a reorganization decreases, thereby increasing the likelihood of all transactions in the reference block being confirmed.

####Block Producer

A node that participates in a process to determine what blocks it is allowed to produce, and then produces blocks that can be broadcast to the network.

####Coda

- "Coda" with a capital C references the underlying cryptocurrency protocol and the network infrastructure that the system depends upon
- "coda" is the unit of the cryptocurrency that is exchanged by participating nodes on the network

####Compressing

Generating a SNARK for a computation output can be thought of as "compressing" that output, as the proofs are fixed size. For example, Coda maintains a succinct blockchain by compressing all the historical data in a blockchain into a zk-SNARK. However, this is computationally different from lossy compression, and the term compress is used to more figuratively describe the process of reducing the size of data required.

####Consensus

An algorithm or set of rules that Coda nodes all agree upon when deciding to update the state of the network. Rules may include what data a new block can contain, and how nodes are selected and rewarded for adding a block. Coda implements Ouroboros Proof-of-Stake as its consensus mechanism.

####Cryptocurrency

A digital asset or currency that uses cryptographic primitives to secure financial transactions and to verify ownership via public-private key pairs.

####Daemon

The Coda daemon is a background process that implements the Coda protocol and runs on a node locally. This allows a local client or wallet to talk to the Coda network. For example, when a CLI is used to issue a command to send a transaction, this request is made to the Coda daemon, which then broadcasts it to the peer-to-peer network. It also listens for events like new blocks and relays this to the client via a [pub-sub](#pub-sub) model.

####Delegating

Because staking coda requires nodes to be online, some nodes may desire to delegate their coda to another node which runs a staking service. This process is called delegating a stake, and often the service provider or staking pool operator may charge a fee for running this service, which will be deducted any time the delegator gets selected to be a block producer.

###Full Node

A Coda node that is able to verify the state of the network trustlessly. In Coda, every node is a full node since all nodes can receive and verify zk-SNARKs.

####Kademlia

A distributed hash table (DHT) for decentralized peer-to-peer networks. Coda uses Kademlia for peer discovery, so that nodes can find neighbor nodes to share information about the network state.

####Node

A node is a machine running the coda daemon. 

####Peer-to-peer

Networking systems that rely on peer nodes to distribute information amongst each other are called peer-to-peer networks. These networks are often distributed in nature, and unlike client-server networking models, do not rely on any centralized resource broker.

####Private Key

The other component in public-key cryptography - private keys are held private while public keys can be issued publicly. Only the holder of the a public key's corresponding private key can attest to ownership of the public key. This allows for signing transactions to prove that you are the honest holder of any funds associated with any given public key.

####Proof-of-Stake

The type of consensus algorithm Coda implements to allow nodes to agree upon the state of the network. Proof-of-Stake (PoS) allows nodes to [stake](#staking) coda on the network to increase their chance of being selected as the next block producer.

####Public Key

One component of public-key cryptography - public keys can be widely shared with the world, and can be thought of as "addresses" or identifiers for the person who holds the corresponding private key.

####Pub-sub

Short for publish-subscribe, pub-sub is a a messaging pattern where message senders broadcast messages, and any listeners that have previously subscribed to that sender's messages will be notified. Coda utilizes this pattern, for example, as a way to notify clients when a new block has been added to the chain. This event can be "heard" by all listeners, and each listener need not independently poll for new data.

####Reorganization

When a competing fork of the blockchain increases in length relative to the main branch, the blockchain undergoes a reorganization to reflect the stronger fork as the main branch. After a reorganization, the transactions on the dropped branch are no longer guaranteed inclusion into the blockchain, and will need to be added to new blocks on the longest branch.

####Signatures

Short for digital signatures, signatures are a way to establish authenticity or ownership of digitally signed messages. This is possible because given a public-private key pair, the owner of the private key can sign a message and create a signature, which can then be verified by anyone with the associated public key.

####SNARK Worker

A node on the network that is participating in SNARK generation.  The SNARK worker is incentivized to help compress transactions because they receive coda as compensation for their efforts.

####Staking

Staking coda allows nodes on the network to increase their chances of being selected as a block producer in accordance with the consensus mechanism. The chance of winning the block scales in proportion to the amount of coda staked. For example, if one node stakes 50% of the available coda in the network, they theoretically have a 50% chance of being selected to produce future blocks. Coda uses Ouroboros Proof-of-Stake to implement the details of staking. If a node chooses to stake its coda, it is required to be online and connected to the Coda network.

####Staking Pool

A pool of delegated funds that is run by a staking pool owner. Other nodes may choose to delegate funds to a staking pool to avoid the requirement of being online.

####User Transaction

A transaction issued by a user - either a payment or a delegation change

####Zero Knowledge Proof

A proof by which one party (a prover) can prove to another party (verifiers) that they have knowledge of something - without giving away that specific knowledge. Coda uses zero knowledge proofs, and specifically, zk-SNARKs, to generate a proof attesting to the blockchain's validity and allowing any node on the network to verify this quickly.

####zk-SNARK

A type of zero-knowledge proof - the acronym stands for zero knowledge succinct non-interactive argument of knowledge. The specific properties of interest in Coda's implementation of SNARKs are succinctness and non-interactivity, which allow for any node to quickly verify the state of the network.
