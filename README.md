# k8s

this is going to hurt a lot less than okd. let's do it

this isn't a ha setup. there's two single points of failure in this setup. if pfsense goes down, routing and nat will go down. if haproxy goes down, you won't be able to reach anything inside the cluster. why? we only have so many ip addresses. i don't want to eat all our 49net ips.
